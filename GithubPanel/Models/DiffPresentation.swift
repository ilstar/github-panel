import Foundation

/// A run of text in a diff line. Changed runs are the words that differ between a paired deletion and addition.
struct DiffSegment: Equatable {
    let text: String
    let isChanged: Bool
}

/// One line as the diff view draws it, with its word-level highlights.
struct DiffDisplayLine: Equatable {
    let kind: DiffLine.Kind
    let oldLineNumber: Int?
    let newLineNumber: Int?
    let segments: [DiffSegment]

    var text: String { segments.map(\.text).joined() }
}

/// One row of the side-by-side view.
enum SplitDiffRow: Equatable {
    /// Hunk headers and notes span both columns.
    case full(DiffDisplayLine)
    /// The old line on the left and the new line on the right. A missing side is drawn blank.
    case pair(left: DiffDisplayLine?, right: DiffDisplayLine?)
}

/// A file's parsed diff, prepared for the unified and split views.
struct DiffPresentation: Equatable {
    let unified: [DiffDisplayLine]
    let split: [SplitDiffRow]

    /// False when every change was hidden, such as a whitespace-only change with whitespace hidden.
    var hasChanges: Bool {
        unified.contains { $0.kind == .addition || $0.kind == .deletion }
    }

    init(lines: [DiffLine], hideWhitespace: Bool) {
        let source = hideWhitespace ? DiffPresentation.hidingWhitespaceChanges(lines) : lines
        let unified = DiffPresentation.highlighted(source)
        self.unified = unified
        self.split = DiffPresentation.splitRows(unified)
    }

    // MARK: - Whitespace

    /// Turns deletion and addition pairs that differ only in whitespace into context lines, like `git diff -w`.
    static func hidingWhitespaceChanges(_ lines: [DiffLine]) -> [DiffLine] {
        var result: [DiffLine] = []
        forEachChangeBlock(in: lines, other: { result.append($0) }, block: { block in
            let deletions = block.filter { $0.kind == .deletion }
            let additions = block.filter { $0.kind == .addition }
            let notes = block.filter { $0.kind == .note }
            let pairs = longestCommonSubsequence(deletions.map { strippingWhitespace($0.text) },
                                                 additions.map { strippingWhitespace($0.text) },
                                                 limit: 250_000)
            guard let pairs, !pairs.isEmpty else {
                result.append(contentsOf: block)
                return
            }
            var deletionIndex = 0
            var additionIndex = 0
            for (matchedDeletion, matchedAddition) in pairs {
                result.append(contentsOf: deletions[deletionIndex..<matchedDeletion])
                result.append(contentsOf: additions[additionIndex..<matchedAddition])
                let addition = additions[matchedAddition]
                result.append(DiffLine(kind: .context,
                                       text: addition.text,
                                       oldLineNumber: deletions[matchedDeletion].oldLineNumber,
                                       newLineNumber: addition.newLineNumber))
                deletionIndex = matchedDeletion + 1
                additionIndex = matchedAddition + 1
            }
            result.append(contentsOf: deletions[deletionIndex...])
            result.append(contentsOf: additions[additionIndex...])
            result.append(contentsOf: notes)
        })
        return result
    }

    private static func strippingWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) })
    }

    // MARK: - Word highlights

    /// Pairs each change block's deletions with its additions in order, then marks the words that differ.
    static func highlighted(_ lines: [DiffLine]) -> [DiffDisplayLine] {
        var result: [DiffDisplayLine] = []
        forEachChangeBlock(in: lines, other: { result.append(plain($0)) }, block: { block in
            let deletions = block.filter { $0.kind == .deletion }
            let additions = block.filter { $0.kind == .addition }
            var deletionSegments: [[DiffSegment]] = deletions.map { [DiffSegment(text: $0.text, isChanged: false)] }
            var additionSegments: [[DiffSegment]] = additions.map { [DiffSegment(text: $0.text, isChanged: false)] }
            for index in 0..<min(deletions.count, additions.count) {
                if let words = wordDiff(old: deletions[index].text, new: additions[index].text) {
                    deletionSegments[index] = words.old
                    additionSegments[index] = words.new
                }
            }
            var deletionIndex = 0
            var additionIndex = 0
            for line in block {
                switch line.kind {
                case .deletion:
                    result.append(DiffDisplayLine(line, segments: deletionSegments[deletionIndex]))
                    deletionIndex += 1
                case .addition:
                    result.append(DiffDisplayLine(line, segments: additionSegments[additionIndex]))
                    additionIndex += 1
                default:
                    result.append(plain(line))
                }
            }
        })
        return result
    }

    /// Splits both lines into words and marks the ones outside their longest common subsequence.
    /// Returns nil when the lines share no words, since highlighting all of both lines adds nothing.
    static func wordDiff(old: String, new: String) -> (old: [DiffSegment], new: [DiffSegment])? {
        let oldTokens = tokens(old)
        let newTokens = tokens(new)
        guard let pairs = longestCommonSubsequence(oldTokens, newTokens, limit: 40_000) else { return nil }
        let sharesWords = pairs.contains { !oldTokens[$0.0].allSatisfy(\.isWhitespace) }
        guard sharesWords else { return nil }

        var oldKept = Set<Int>()
        var newKept = Set<Int>()
        for (oldIndex, newIndex) in pairs {
            oldKept.insert(oldIndex)
            newKept.insert(newIndex)
        }
        return (segments(oldTokens, kept: oldKept), segments(newTokens, kept: newKept))
    }

    /// Word characters group together, whitespace groups together, and every other character stands alone.
    static func tokens(_ text: String) -> [String] {
        enum Group { case word, space, other }
        func group(_ character: Character) -> Group {
            if character.isLetter || character.isNumber || character == "_" { return .word }
            if character.isWhitespace { return .space }
            return .other
        }

        var result: [String] = []
        var current = ""
        var currentGroup: Group?
        for character in text {
            let characterGroup = group(character)
            if characterGroup == currentGroup, characterGroup != .other {
                current.append(character)
            } else {
                if !current.isEmpty { result.append(current) }
                current = String(character)
                currentGroup = characterGroup
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func segments(_ tokens: [String], kept: Set<Int>) -> [DiffSegment] {
        var changed = tokens.indices.map { !kept.contains($0) }
        // Whitespace between two changed words reads as part of one change.
        for index in tokens.indices.dropFirst().dropLast()
        where !changed[index] && changed[index - 1] && changed[index + 1] && tokens[index].allSatisfy(\.isWhitespace) {
            changed[index] = true
        }

        var result: [DiffSegment] = []
        for (index, token) in tokens.enumerated() {
            if let last = result.last, last.isChanged == changed[index] {
                result[result.count - 1] = DiffSegment(text: last.text + token, isChanged: last.isChanged)
            } else {
                result.append(DiffSegment(text: token, isChanged: changed[index]))
            }
        }
        return result.isEmpty ? [DiffSegment(text: "", isChanged: false)] : result
    }

    // MARK: - Split rows

    static func splitRows(_ lines: [DiffDisplayLine]) -> [SplitDiffRow] {
        var rows: [SplitDiffRow] = []
        var deletions: [DiffDisplayLine] = []
        var additions: [DiffDisplayLine] = []
        var notes: [DiffDisplayLine] = []

        func flush() {
            for index in 0..<max(deletions.count, additions.count) {
                rows.append(.pair(left: index < deletions.count ? deletions[index] : nil,
                                  right: index < additions.count ? additions[index] : nil))
            }
            rows.append(contentsOf: notes.map(SplitDiffRow.full))
            deletions = []
            additions = []
            notes = []
        }

        for line in lines {
            switch line.kind {
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .note:
                notes.append(line)
            case .context:
                flush()
                rows.append(.pair(left: line, right: line))
            case .hunk:
                flush()
                rows.append(.full(line))
            }
        }
        flush()
        return rows
    }

    // MARK: - Helpers

    /// Calls `block` with each run of deletions, additions, and notes, and `other` with every other line.
    private static func forEachChangeBlock(in lines: [DiffLine],
                                           other: (DiffLine) -> Void,
                                           block: ([DiffLine]) -> Void) {
        var current: [DiffLine] = []
        for line in lines {
            switch line.kind {
            case .deletion, .addition, .note:
                current.append(line)
            case .hunk, .context:
                if !current.isEmpty { block(current) }
                current = []
                other(line)
            }
        }
        if !current.isEmpty { block(current) }
    }

    private static func plain(_ line: DiffLine) -> DiffDisplayLine {
        DiffDisplayLine(line, segments: [DiffSegment(text: line.text, isChanged: false)])
    }

    /// Index pairs of the longest common subsequence, in order. Returns nil when the inputs are too large to compare.
    static func longestCommonSubsequence(_ a: [String], _ b: [String], limit: Int) -> [(Int, Int)]? {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        guard a.count * b.count <= limit else { return nil }

        let columns = b.count + 1
        var lengths = [Int](repeating: 0, count: (a.count + 1) * columns)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lengths[i * columns + j] = a[i] == b[j]
                    ? lengths[(i + 1) * columns + j + 1] + 1
                    : max(lengths[(i + 1) * columns + j], lengths[i * columns + j + 1])
            }
        }

        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}

private extension DiffDisplayLine {
    init(_ line: DiffLine, segments: [DiffSegment]) {
        self.init(kind: line.kind,
                  oldLineNumber: line.oldLineNumber,
                  newLineNumber: line.newLineNumber,
                  segments: segments)
    }
}
