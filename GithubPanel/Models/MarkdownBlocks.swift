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
    /// Blocks inside an HTML element like `<div align="center">`.
    case centered([MarkdownBlock])
}

enum MarkdownTableAlignment: Equatable {
    case leading, center, trailing
}

/// A small line-based Markdown parser that covers what PR descriptions usually use.
/// The HTML GitHub allows in Markdown is rendered too: block tags like `<div>`, `<p>`, `<h2>`
/// and `<br>` shape the blocks, and inline tags become Markdown or are dropped.
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
        // Whether each open HTML block element centers its content, and the blocks collected while one does.
        var htmlElements: [Bool] = []
        var centered: [MarkdownBlock]?

        func emit(_ block: MarkdownBlock) {
            if centered != nil {
                centered?.append(block)
            } else {
                blocks.append(block)
            }
        }

        func takeParagraph() -> String {
            defer { paragraph = [] }
            return inlineHTML(paragraph.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func flushParagraph() {
            let text = takeParagraph()
            if !text.isEmpty { emit(.paragraph(text)) }
        }

        func flushQuote() {
            guard !quote.isEmpty else { return }
            emit(.quote(inlineHTML(quote.joined(separator: "\n"))))
            quote = []
        }

        func updateCentering() {
            let shouldCenter = htmlElements.contains(true)
            if shouldCenter, centered == nil {
                centered = []
            } else if !shouldCenter, let group = centered {
                centered = nil
                if !group.isEmpty { blocks.append(.centered(group)) }
            }
        }

        /// Applies a line that starts with an HTML block tag, like `<div align="center">` or `<h2>Title</h2>`.
        func applyHTMLLine(_ line: String) {
            var rest = Substring(line)
            var text = ""
            var headingLevel: Int?
            func appendText() {
                if !text.trimmingCharacters(in: .whitespaces).isEmpty { paragraph.append(text) }
                text = ""
            }
            while let open = rest.firstIndex(of: "<") {
                guard let tag = htmlTag(in: rest, at: open), blockHTMLTags.contains(tag.name) else {
                    text += rest[...open]
                    rest = rest[rest.index(after: open)...]
                    continue
                }
                text += rest[..<open]
                appendText()
                rest = rest[tag.end...]
                switch tag.name {
                case "br":
                    flushParagraph()
                case "hr":
                    flushParagraph()
                    emit(.rule)
                case "summary":
                    let content = takeParagraph()
                    if tag.isClosing, !content.isEmpty { emit(.paragraph("**\(content)**")) }
                case _ where tag.name.count == 2 && tag.name.hasPrefix("h"):
                    let content = takeParagraph()
                    if tag.isClosing, let level = headingLevel, !content.isEmpty {
                        emit(.heading(level: level, text: content))
                    } else if !content.isEmpty {
                        emit(.paragraph(content))
                    }
                    headingLevel = tag.isClosing ? nil : Int(tag.name.dropFirst())
                default:
                    flushParagraph()
                    if tag.isClosing {
                        _ = htmlElements.popLast()
                    } else if !tag.isSelfClosing {
                        htmlElements.append(tag.name == "center" || tag.centersContent)
                    }
                    updateCentering()
                }
            }
            text += rest
            appendText()
            if let level = headingLevel {
                let content = takeParagraph()
                if !content.isEmpty { emit(.heading(level: level, text: content)) }
            }
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
                    emit(.code(language: open.language, text: open.lines.joined(separator: "\n")))
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
            } else if startsWithBlockHTMLTag(trimmed) {
                applyHTMLLine(trimmed)
            } else if let heading = heading(trimmed) {
                flushParagraph()
                emit(heading)
            } else if index < lines.count, let header = tableCells(trimmed),
                      let alignments = tableAlignments(String(lines[index])), alignments.count == header.count {
                flushParagraph()
                index += 1
                var rows: [[String]] = []
                while index < lines.count {
                    let rowLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let cells = tableCells(rowLine) else { break }
                    rows.append((0..<header.count).map { $0 < cells.count ? inlineHTML(cells[$0]) : "" })
                    index += 1
                }
                emit(.table(header: header.map(inlineHTML), alignments: alignments, rows: rows))
            } else if isRule(trimmed) {
                flushParagraph()
                emit(.rule)
            } else if let item = listItem(line) {
                flushParagraph()
                if let task = taskItem(item.content) {
                    emit(.task(index: taskBoxes.count, checked: task.checked, indent: item.indent,
                               text: inlineHTML(task.text)))
                    taskBoxes.append(task.box)
                } else {
                    emit(.listItem(marker: item.marker, indent: item.indent,
                                   text: inlineHTML(item.content.trimmingCharacters(in: .whitespaces))))
                }
            } else {
                paragraph.append(trimmed)
            }
        }

        flushParagraph()
        flushQuote()
        if let open = code {
            emit(.code(language: open.language, text: open.lines.joined(separator: "\n")))
        }
        htmlElements = []
        updateCentering()
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
        return .heading(level: hashes, text: inlineHTML(rest.trimmingCharacters(in: .whitespaces)))
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

    // MARK: - HTML

    /// Tags that start, end, or split blocks.
    private static let blockHTMLTags: Set<String> = [
        "div", "p", "center", "details", "summary", "br", "hr", "h1", "h2", "h3", "h4", "h5", "h6"
    ]

    /// Tags that become Markdown inside a block, or are dropped, keeping their text.
    private static let inlineHTMLTags: Set<String> = [
        "a", "b", "strong", "i", "em", "s", "del", "strike", "code", "kbd", "br", "img",
        "span", "sub", "sup", "small", "big", "u", "ins", "mark", "picture", "source",
        "table", "thead", "tbody", "tr", "td", "th", "div", "p", "center", "details", "summary",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr"
    ]

    private struct HTMLTag {
        let name: String
        let isClosing: Bool
        let isSelfClosing: Bool
        let attributes: Substring
        /// The index just past the tag's `>`.
        let end: String.Index

        func attribute(_ name: String) -> String? {
            var rest = attributes[...]
            while let range = rest.range(of: name, options: .caseInsensitive) {
                let before = range.lowerBound == attributes.startIndex ? " " : attributes[attributes.index(before: range.lowerBound)]
                var value = rest[range.upperBound...].drop { $0 == " " }
                rest = rest[range.upperBound...]
                guard before.isWhitespace, value.first == "=" else { continue }
                value = value.dropFirst().drop { $0 == " " }
                if let quote = value.first, quote == "\"" || quote == "'" {
                    return String(value.dropFirst().prefix { $0 != quote })
                }
                return String(value.prefix { !$0.isWhitespace && $0 != "/" })
            }
            return nil
        }

        var centersContent: Bool {
            attribute("align")?.lowercased() == "center"
        }
    }

    /// The HTML tag starting at `start`, which must be a `<`.
    private static func htmlTag(in text: Substring, at start: String.Index) -> HTMLTag? {
        var index = text.index(after: start)
        let isClosing = index < text.endIndex && text[index] == "/"
        if isClosing { index = text.index(after: index) }
        let nameStart = index
        while index < text.endIndex, text[index].isASCII, text[index].isLetter || text[index].isNumber {
            index = text.index(after: index)
        }
        guard nameStart < index, text[nameStart].isLetter,
              let close = text[index...].firstIndex(of: ">") else { return nil }
        let next = index < text.endIndex ? text[index] : ">"
        guard next == ">" || next == "/" || next.isWhitespace else { return nil }
        let attributes = text[index..<close]
        return HTMLTag(name: text[nameStart..<index].lowercased(), isClosing: isClosing,
                       isSelfClosing: attributes.hasSuffix("/"), attributes: attributes,
                       end: text.index(after: close))
    }

    private static func startsWithBlockHTMLTag(_ line: String) -> Bool {
        guard line.first == "<", let tag = htmlTag(in: line[...], at: line.startIndex) else { return false }
        return blockHTMLTags.contains(tag.name)
    }

    /// Inline Markdown with GitHub's allowed HTML tags turned into Markdown or dropped, and entities decoded.
    /// Text inside code spans is left alone.
    static func inlineHTML(_ text: String) -> String {
        guard text.contains("<") || text.contains("&") else { return text }
        var result = ""
        var links: [String?] = []
        var inCode = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "`" {
                inCode.toggle()
            } else if !inCode, character == "<", let tag = htmlTag(in: text[...], at: index),
                      inlineHTMLTags.contains(tag.name) {
                result += markdown(for: tag, links: &links)
                index = tag.end
                continue
            } else if !inCode, character == "&", let (decoded, end) = htmlEntity(in: text, at: index) {
                result += decoded
                index = end
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    private static func markdown(for tag: HTMLTag, links: inout [String?]) -> String {
        switch tag.name {
        case "b", "strong": return "**"
        case "i", "em": return "*"
        case "s", "del", "strike": return "~~"
        case "code", "kbd": return "`"
        case "br": return "\n"
        case "img": return tag.isClosing ? "" : tag.attribute("alt") ?? ""
        case "a":
            if tag.isClosing {
                guard let link = links.popLast() else { return "" }
                return link.map { "](\($0))" } ?? ""
            }
            let href = tag.attribute("href").flatMap { $0.isEmpty ? nil : $0 }
            links.append(href)
            return href == nil ? "" : "["
        case "td", "th": return tag.isClosing ? " " : ""
        default: return ""
        }
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "mdash": "—", "ndash": "–", "hellip": "…", "copy": "©", "middot": "·"
    ]

    /// The character an entity like `&amp;` or `&#128640;` stands for, and the index past its `;`.
    private static func htmlEntity(in text: String, at start: String.Index) -> (String, String.Index)? {
        let body = text[text.index(after: start)...].prefix(10)
        guard let semicolon = body.firstIndex(of: ";") else { return nil }
        let name = body[..<semicolon]
        let end = text.index(after: semicolon)
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let scalar = value.flatMap(Unicode.Scalar.init) else { return nil }
            return (String(Character(scalar)), end)
        }
        return namedEntities[String(name)].map { ($0, end) }
    }
}
