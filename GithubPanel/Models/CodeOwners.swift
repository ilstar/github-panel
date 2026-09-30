import Foundation

/// CODEOWNERS uses the last matching rule, including rules that deliberately clear ownership.
struct CodeOwners {
    private struct Rule {
        let expression: NSRegularExpression
        let owners: [String]
    }
    private let rules: [Rule]

    init(_ text: String) {
        rules = text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard let pattern = fields.first, !pattern.hasPrefix("!"),
                  !pattern.contains("["), !pattern.contains("\\") else { return nil }
            let rooted = pattern.hasPrefix("/") || pattern.dropLast().contains("/")
            let path = pattern.hasPrefix("/") ? String(pattern.dropFirst()) : pattern
            let chars = Array(path)
            var regex = rooted ? "^" : "(?:^|/)"
            var index = 0
            while index < chars.count {
                switch chars[index] {
                case "*":
                    if index + 1 < chars.count, chars[index + 1] == "*" {
                        index += 1
                        if index + 1 < chars.count, chars[index + 1] == "/" {
                            regex += "(?:.*/)?"
                            index += 1
                        } else {
                            regex += ".*"
                        }
                    } else {
                        regex += "[^/]*"
                    }
                case "?": regex += "[^/]"
                default: regex += NSRegularExpression.escapedPattern(for: String(chars[index]))
                }
                index += 1
            }
            if path.hasSuffix("/") {
                regex += ".*$"
            } else if path.hasSuffix("*") || path.hasSuffix("?") {
                regex += "$"
            } else {
                regex += "(?:/.*)?$"
            }
            guard let expression = try? NSRegularExpression(pattern: regex) else { return nil }
            return Rule(expression: expression, owners: Array(fields.dropFirst()))
        }
    }

    func owners(for path: String) -> [String] {
        rules.last { $0.expression.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil }?.owners ?? []
    }

    static func isOwnedByViewer(_ owners: [String], login: String, email: String?, teams: Set<String>) -> Bool {
        let identities = teams.union(["@" + login.lowercased()]).union(email.map { [$0.lowercased()] } ?? [])
        return owners.contains { identities.contains($0.lowercased()) }
    }
}
