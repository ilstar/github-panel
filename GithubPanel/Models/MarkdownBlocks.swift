import Foundation

/// A block of a pull request description. Inline Markdown (bold, links, code)
/// inside `text` is rendered separately with `AttributedString`.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case listItem(marker: String, indent: Int, text: String)
    /// A task list item like `- [x] Done`. `index` counts the description's task items from zero.
    case task(index: Int, checked: Bool, indent: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case table(header: [String], alignments: [MarkdownTableAlignment], rows: [[String]])
    case rule
}

enum MarkdownTableAlignment: Equatable {
    case leading, center, trailing
}

/// A small line-based Markdown parser that covers what PR descriptions usually use.
enum MarkdownBlocks {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        parseBlocks(strippingHTMLComments(markdown).text).blocks
    }

    /// The Markdown with one task item checked or unchecked, like clicking its box on GitHub.
    /// Only the character between the brackets changes. Nil when there is no such task item.
    static func settingTask(_ index: Int, checked: Bool, in markdown: String) -> String? {
        let stripped = strippingHTMLComments(markdown)
        let boxes = parseBlocks(stripped.text).taskBoxes
        guard boxes.indices.contains(index) else { return nil }
        // Find the box in the original text by walking the pieces the comments were cut from.
        var offset = stripped.text.utf8.distance(from: stripped.text.startIndex, to: boxes[index])
        for piece in stripped.pieces {
            let count = piece.utf8.count
            guard offset >= count else {
                let box = markdown.utf8.index(piece.startIndex, offsetBy: offset)
                guard " xX".contains(markdown[box]) else { return nil }
                if (markdown[box] != " ") == checked { return markdown }
                var result = markdown
                result.replaceSubrange(box...box, with: checked ? "x" : " ")
                return result
            }
            offset -= count
        }
        return nil
    }

    /// The blocks, and where each task item's box character sits in `text`.
    private static func parseBlocks(_ text: String) -> (blocks: [MarkdownBlock], taskBoxes: [String.Index]) {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: (language: String?, lines: [String])?
        var taskBoxes: [String.Index] = []

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

        // Lines stay slices of `text` so task boxes can be traced back to it.
        let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var open = code {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
                    code = nil
                } else {
                    open.lines.append(String(line))
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
            } else if index < lines.count, let header = tableCells(trimmed),
                      let alignments = tableAlignments(String(lines[index])), alignments.count == header.count {
                flushParagraph()
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let cells = tableCells(rowLine) else { break }
                    rows.append((0..<header.count).map { $0 < cells.count ? cells[$0] : "" })
                    index += 1
                }
                blocks.append(.table(header: header, alignments: alignments, rows: rows))
            } else if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                if let task = taskItem(item.content) {
                    blocks.append(.task(index: taskBoxes.count, checked: task.checked, indent: item.indent, text: task.text))
                    taskBoxes.append(task.box)
                } else {
                    blocks.append(.listItem(marker: item.marker, indent: item.indent,
                                            text: item.content.trimmingCharacters(in: .whitespaces)))
                }
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        flushQuote()
        if let open = code {
            blocks.append(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        return (blocks, taskBoxes)
    }

    /// The text without HTML comments, and the pieces of the original text it was joined from.
    private static func strippingHTMLComments(_ text: String) -> (text: String, pieces: [Substring]) {
        var pieces: [Substring] = []
        var rest = Substring(text)
        while let start = rest.range(of: "<!--") {
            pieces.append(rest[..<start.lowerBound])
            guard let end = rest[start.upperBound...].range(of: "-->") else {
                rest = rest[rest.endIndex...]
                break
            }
            rest = rest[end.upperBound...]
        }
        pieces.append(rest)
        return (pieces.joined(), pieces)
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

    /// The cells of a pipe table row, or nil when the line has no unescaped `|`.
    private static func tableCells(_ line: String) -> [String]? {
        var cells: [String] = []
        var cell = ""
        var sawPipe = false
        var escaped = false
        for character in line {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                sawPipe = true
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        guard sawPipe else { return nil }
        cells.append(cell)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The column alignments of a delimiter row like `| :--- | :---: | ---: |`.
    private static func tableAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        guard let cells = tableCells(line.trimmingCharacters(in: .whitespaces)), !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    /// A list item's marker, nesting level, and the text after the marker.
    private static func listItem(_ line: Substring) -> (marker: String, indent: Int, content: Substring)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(leading.count)

        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return ("•", indent, rest.dropFirst(2))
        }

        let digits = rest.prefix { $0.isNumber }
        let afterDigits = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 9, afterDigits.first == "." || afterDigits.first == ")",
           afterDigits.dropFirst().first == " " {
            return ("\(digits).", indent, afterDigits.dropFirst(2))
        }
        return nil
    }

    /// The box of a task item like `[ ] To do` or `[x] Done`, found at the start of a list item's text.
    private static func taskItem(_ content: Substring) -> (checked: Bool, box: String.Index, text: String)? {
        let rest = content.drop { $0 == " " }
        guard rest.first == "[" else { return nil }
        let box = rest.index(after: rest.startIndex)
        guard box < rest.endIndex, " xX".contains(rest[box]) else { return nil }
        let close = rest.index(after: box)
        guard close < rest.endIndex, rest[close] == "]" else { return nil }
        let text = rest[rest.index(after: close)...]
        guard text.isEmpty || text.first == " " || text.first == "\t" else { return nil }
        return (rest[box] != " ", box, text.trimmingCharacters(in: .whitespaces))
    }
}
