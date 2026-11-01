import Foundation

/// A GitHub user the @mention menu offers.
struct MentionCandidate: Identifiable, Equatable {
    let login: String
    /// The user's full name, when they set one.
    var name: String?

    var id: String { login.lowercased() }

    /// The most the menu shows at once.
    static let limit = 10

    /// People with access to the repository first, then everyone else on GitHub, each once, up to `limit`.
    static func merged(repository: [MentionCandidate], everyone: [MentionCandidate]) -> [MentionCandidate] {
        var seen: Set<String> = []
        return Array((repository + everyone).filter { seen.insert($0.id).inserted }.prefix(limit))
    }
}

/// The "@name" being typed at the cursor, which the @mention menu completes.
/// Ranges are in UTF-16 offsets, like `NSTextView`'s.
struct MentionQuery: Equatable {
    /// The "@" and the whole word after it, including any part after the cursor.
    let range: NSRange
    /// What was typed between the "@" and the cursor.
    let text: String

    /// GitHub logins are at most 39 characters; a longer word is not a mention.
    static let maxLength = 39

    /// The mention the cursor is in, or nil. Like GitHub, an "@" only starts a mention at the start of a word,
    /// so an email address does not.
    static func active(in string: String, caret: Int) -> MentionQuery? {
        let string = string as NSString
        guard caret >= 0, caret <= string.length else { return nil }

        var start = caret
        while start > 0, isMentionCharacter(string.character(at: start - 1)) {
            start -= 1
        }
        guard start > 0, string.character(at: start - 1) == at, caret - start <= maxLength else { return nil }
        let atIndex = start - 1
        if atIndex > 0, startsNoMention(after: string.character(at: atIndex - 1)) { return nil }

        var end = caret
        while end < string.length, isMentionCharacter(string.character(at: end)) {
            end += 1
        }
        return MentionQuery(range: NSRange(location: atIndex, length: end - atIndex),
                            text: string.substring(with: NSRange(location: start, length: caret - start)))
    }

    /// The text that replaces `range` to mention `login`, and where the cursor goes after it.
    /// Adds a space after the mention unless one already follows it.
    func completion(for login: String, in string: String) -> (replacement: String, caret: Int) {
        let string = string as NSString
        let end = NSMaxRange(range)
        let followedBySpace = end < string.length
            && CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: end)) ?? " ")
        let replacement = "@\(login)" + (followedBySpace ? "" : " ")
        return (replacement, range.location + (replacement as NSString).length + (followedBySpace ? 1 : 0))
    }

    private static let at = unichar(UInt8(ascii: "@"))

    /// Letters, digits, "-" and "_", so a search can match a login or a name.
    private static func isMentionCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
    }

    /// An "@" right after a word character, "`", "/", "." or another "@" is part of something else, such as an email or a path.
    private static func startsNoMention(after character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return isMentionCharacter(character) || "`/@.".unicodeScalars.contains(scalar)
    }
}
