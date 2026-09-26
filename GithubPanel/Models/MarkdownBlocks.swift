import Foundation

/// A block of a pull request description. Inline Markdown (bold, links, code)
/// inside `text` is rendered separately with `AttributedString`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, indent: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule
}

/// A small line-based Markdown parser that covers what PR descriptions usually use.
enum MarkdownBlocks {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: (language: String?, lines: [String])?

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            blocks.append(.quote(quote.joined(separator: "\n")))
            quote = []
        }

        let normalized = stripHTMLComments(markdown).replacingOccurrences(of: "\r\n", with: "\n")
        for line in normalized.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(line)
                    code = open
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushParagraph()
                flushQuote()
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                code = (language.isEmpty ? nil : language, [])
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            flushQuote()

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                blocks.append(item)
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        flushQuote()
        if let open = code {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        return blocks
    }

    static func stripHTMLComments(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "<!--") {
            result += rest[..<start.lowerBound]
            guard let end = rest[start.upperBound...].range(of: "-->") else {
                return result
            }
            rest = rest[end.upperBound...]
        }
        return result + rest
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        guard rest.first == " " else { return nil }
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func listItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(leading.count)

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return .listItem(marker: "•", indent: indent, text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }

        let digits = rest.prefix { $0.isNumber }
        let afterDigits = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9, afterDigits.first == "." || afterDigits.first == ")",
           afterDigits.dropFirst().first == " " {
            return .listItem(marker: "\(digits).", indent: indent, text: afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
