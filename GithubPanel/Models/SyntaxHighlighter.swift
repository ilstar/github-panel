import Foundation

/// What a run of code is, for coloring it in the diff.
enum SyntaxKind: Equatable {
    case keyword
    case string
    case number
    case comment
    /// A capitalized name, such as a class or struct, in languages that name types that way.
    case type
    /// Decorators, annotations, attributes, and symbols such as `@objc` or Ruby's `:name`.
    case attribute
}

/// A colored run of a line, as character offsets into the line's text.
struct SyntaxToken: Equatable {
    let range: Range<Int>
    let kind: SyntaxKind
}

/// The rules for lexing one language. Lexing is token by token, not a full grammar, which is enough to color
/// a diff and fast enough to run on every line of a large pull request.
struct SyntaxLanguage: Equatable {
    let lineComments: [String]
    /// Delimiters that can span lines, such as `/* */` comments or Python's `"""` strings.
    let blocks: [Block]
    let quotes: Set<Character>
    let keywords: Set<String>
    /// Colors capitalized names as types.
    let capitalizedTypes: Bool
    /// The prefix that starts a decorator or attribute, such as `@`.
    let attributePrefix: Character?
    /// Colors Ruby-style `:symbol`s.
    let symbols: Bool
    /// Colors shell-style `$variables`.
    let dollarVariables: Bool

    struct Block: Equatable {
        let open: String
        let close: String
        let kind: SyntaxKind
    }

    /// The language for a file, by its name or extension. Nil for files with no known language.
    init?(filename: String) {
        let name = (filename as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        switch name {
        case "Dockerfile", "Makefile", "Gemfile", "Rakefile", "Podfile", "Brewfile", "Fastfile", "Vagrantfile":
            self = name == "Dockerfile" || name == "Makefile" ? Self.shell : Self.ruby
            return
        default:
            break
        }
        guard let language = Self.byExtension[ext] else { return nil }
        self = language
    }

    init(lineComments: [String] = [],
         blocks: [Block] = [],
         quotes: Set<Character> = ["\"", "'"],
         keywords: Set<String> = [],
         capitalizedTypes: Bool = false,
         attributePrefix: Character? = nil,
         symbols: Bool = false,
         dollarVariables: Bool = false) {
        self.lineComments = lineComments
        self.blocks = blocks
        self.quotes = quotes
        self.keywords = keywords
        self.capitalizedTypes = capitalizedTypes
        self.attributePrefix = attributePrefix
        self.symbols = symbols
        self.dollarVariables = dollarVariables
    }

    // MARK: - Languages

    private static let cComment = Block(open: "/*", close: "*/", kind: .comment)

    static let swift = SyntaxLanguage(
        lineComments: ["//"], blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), cComment], quotes: ["\""],
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
                   "continue", "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                   "false", "fileprivate", "final", "for", "func", "guard", "if", "import", "in", "init", "inout",
                   "internal", "is", "lazy", "let", "mutating", "nil", "nonisolated", "open", "operator", "override",
                   "private", "protocol", "public", "repeat", "rethrows", "return", "self", "Self", "some", "static",
                   "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
                   "weak", "where", "while"],
        capitalizedTypes: true, attributePrefix: "@")

    static let cFamily = SyntaxLanguage(
        lineComments: ["//"], blocks: [cComment],
        keywords: ["auto", "bool", "break", "case", "char", "class", "const", "constexpr", "continue", "default",
                   "delete", "do", "double", "else", "enum", "explicit", "extern", "false", "float", "for", "friend",
                   "goto", "if", "inline", "int", "long", "namespace", "new", "nullptr", "NULL", "operator",
                   "private", "protected", "public", "return", "self", "short", "signed", "sizeof", "static",
                   "struct", "switch", "template", "this", "throw", "true", "try", "typedef", "typename", "union",
                   "unsigned", "using", "virtual", "void", "volatile", "while", "YES", "NO", "nil", "id",
                   "#include", "#import", "#define", "#if", "#ifdef", "#ifndef", "#else", "#endif", "#pragma"],
        capitalizedTypes: true, attributePrefix: "@")

    static let javaScript = SyntaxLanguage(
        lineComments: ["//"], blocks: [cComment], quotes: ["\"", "'", "`"],
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor",
                   "continue", "debugger", "declare", "default", "delete", "do", "else", "enum", "export",
                   "extends", "false", "finally", "for", "from", "function", "get", "if", "implements", "import",
                   "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of", "private",
                   "protected", "public", "readonly", "return", "set", "static", "super", "switch", "this", "throw",
                   "true", "try", "type", "typeof", "undefined", "var", "void", "while", "yield"],
        capitalizedTypes: true, attributePrefix: "@")

    static let java = SyntaxLanguage(
        lineComments: ["//"], blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), cComment],
        keywords: ["abstract", "as", "boolean", "break", "byte", "case", "catch", "char", "class", "companion",
                   "const", "continue", "data", "default", "do", "double", "else", "enum", "extends", "false",
                   "final", "finally", "float", "for", "fun", "if", "implements", "import", "in", "instanceof",
                   "int", "interface", "is", "long", "new", "null", "object", "override", "package", "private",
                   "protected", "public", "record", "return", "sealed", "short", "static", "super", "switch",
                   "this", "throw", "throws", "true", "try", "val", "var", "void", "when", "while"],
        capitalizedTypes: true, attributePrefix: "@")

    static let cSharp = SyntaxLanguage(
        lineComments: ["//"], blocks: [cComment],
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const",
                   "continue", "default", "do", "double", "else", "enum", "false", "finally", "for", "foreach",
                   "if", "in", "int", "interface", "internal", "is", "namespace", "new", "null", "out", "override",
                   "private", "protected", "public", "readonly", "record", "ref", "return", "sealed", "static",
                   "string", "struct", "switch", "this", "throw", "true", "try", "using", "var", "virtual", "void",
                   "while"],
        capitalizedTypes: true)

    static let go = SyntaxLanguage(
        lineComments: ["//"], blocks: [cComment], quotes: ["\"", "'", "`"],
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                   "false", "for", "func", "go", "goto", "if", "import", "interface", "iota", "map", "nil",
                   "package", "range", "return", "select", "struct", "switch", "true", "type", "var"],
        capitalizedTypes: true)

    static let rust = SyntaxLanguage(
        lineComments: ["//"], blocks: [cComment], quotes: ["\""],
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern",
                   "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub",
                   "ref", "return", "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe",
                   "use", "where", "while"],
        capitalizedTypes: true, attributePrefix: "#")

    static let python = SyntaxLanguage(
        lineComments: ["#"],
        blocks: [Block(open: "\"\"\"", close: "\"\"\"", kind: .string), Block(open: "'''", close: "'''", kind: .string)],
        keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
                   "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in", "is",
                   "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "self", "True", "try",
                   "while", "with", "yield"],
        capitalizedTypes: true, attributePrefix: "@")

    static let ruby = SyntaxLanguage(
        lineComments: ["#"], blocks: [Block(open: "=begin", close: "=end", kind: .comment)],
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif",
                   "end", "ensure", "extend", "false", "for", "if", "in", "include", "module", "next", "nil", "not",
                   "or", "private", "protected", "public", "raise", "redo", "require", "require_relative", "rescue",
                   "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while",
                   "yield", "attr_reader", "attr_writer", "attr_accessor"],
        capitalizedTypes: true, symbols: true)

    static let shell = SyntaxLanguage(
        lineComments: ["#"],
        keywords: ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
                   "local", "readonly", "return", "set", "source", "then", "unset", "until", "while",
                   "FROM", "RUN", "CMD", "COPY", "ADD", "ENV", "ARG", "WORKDIR", "EXPOSE", "ENTRYPOINT", "USER",
                   "LABEL", "VOLUME", "AS"],
        dollarVariables: true)

    static let yaml = SyntaxLanguage(lineComments: ["#"], keywords: ["true", "false", "null", "yes", "no", "on", "off"])

    static let json = SyntaxLanguage(quotes: ["\""], keywords: ["true", "false", "null"])

    static let css = SyntaxLanguage(lineComments: ["//"], blocks: [cComment],
                                    keywords: ["!important", "@media", "@import", "@include", "@mixin", "@extend"],
                                    dollarVariables: true)

    static let sql = SyntaxLanguage(
        lineComments: ["--"], blocks: [cComment],
        keywords: Set(["add", "alter", "and", "as", "asc", "by", "case", "column", "create", "delete", "desc",
                       "distinct", "drop", "else", "end", "exists", "from", "group", "having", "in", "index",
                       "inner", "insert", "into", "is", "join", "left", "limit", "not", "null", "on", "or", "order",
                       "outer", "primary", "key", "references", "right", "select", "set", "table", "then", "union",
                       "unique", "update", "values", "when", "where", "with"].flatMap { [$0, $0.uppercased()] }))

    static let php = SyntaxLanguage(
        lineComments: ["//", "#"], blocks: [cComment],
        keywords: ["abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default",
                   "echo", "else", "elseif", "extends", "false", "final", "finally", "fn", "for", "foreach",
                   "function", "if", "implements", "interface", "namespace", "new", "null", "private",
                   "protected", "public", "return", "static", "switch", "throw", "trait", "true", "try", "use",
                   "while"],
        capitalizedTypes: true, dollarVariables: true)

    static let toml = SyntaxLanguage(lineComments: ["#"], keywords: ["true", "false"])

    private static let byExtension: [String: SyntaxLanguage] = {
        var map: [String: SyntaxLanguage] = [:]
        func add(_ language: SyntaxLanguage, _ extensions: [String]) {
            for ext in extensions { map[ext] = language }
        }
        add(swift, ["swift"])
        add(cFamily, ["c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "hh"])
        add(javaScript, ["js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts"])
        add(java, ["java", "kt", "kts", "scala", "groovy", "gradle"])
        add(cSharp, ["cs"])
        add(go, ["go"])
        add(rust, ["rs"])
        add(python, ["py", "pyi"])
        add(ruby, ["rb", "rake", "gemspec", "ru", "rbi"])
        add(shell, ["sh", "bash", "zsh", "fish", "mk"])
        add(yaml, ["yml", "yaml"])
        add(json, ["json", "jsonc"])
        add(css, ["css", "scss", "sass", "less"])
        add(sql, ["sql"])
        add(php, ["php"])
        add(toml, ["toml", "ini", "cfg", "conf"])
        return map
    }()
}

/// Colors lines of code one at a time, carrying open block comments and strings from one line to the next.
enum SyntaxHighlighter {
    /// The open multi-line block a line ends inside, if any.
    typealias State = SyntaxLanguage.Block?

    static func tokens(_ line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        tokens(line, language: language, state: nil).tokens
    }

    /// The line's tokens, and the block it leaves open for the next line.
    static func tokens(_ line: String, language: SyntaxLanguage, state: State) -> (tokens: [SyntaxToken], state: State) {
        let characters = Array(line)
        var tokens: [SyntaxToken] = []
        var index = 0

        func matches(_ text: String, at position: Int) -> Bool {
            var offset = position
            for character in text {
                guard offset < characters.count, characters[offset] == character else { return false }
                offset += 1
            }
            return true
        }

        /// Finds the end of `block` from `position`, returning the index after its close, or nil if it runs past the line.
        func closeBlock(_ block: SyntaxLanguage.Block, from position: Int) -> Int? {
            var offset = position
            while offset < characters.count {
                if block.kind == .string, characters[offset] == "\\" {
                    offset += 2
                    continue
                }
                if matches(block.close, at: offset) { return offset + block.close.count }
                offset += 1
            }
            return nil
        }

        if let open = state {
            guard let end = closeBlock(open, from: 0) else {
                return (characters.isEmpty ? [] : [SyntaxToken(range: 0..<characters.count, kind: open.kind)], open)
            }
            tokens.append(SyntaxToken(range: 0..<end, kind: open.kind))
            index = end
        }

        while index < characters.count {
            let character = characters[index]
            let previous: Character? = index > 0 ? characters[index - 1] : nil

            if language.lineComments.contains(where: { matches($0, at: index) }) {
                tokens.append(SyntaxToken(range: index..<characters.count, kind: .comment))
                return (tokens, nil)
            }

            if let block = language.blocks.first(where: { matches($0.open, at: index) }) {
                let start = index
                guard let end = closeBlock(block, from: index + block.open.count) else {
                    tokens.append(SyntaxToken(range: start..<characters.count, kind: block.kind))
                    return (tokens, block)
                }
                tokens.append(SyntaxToken(range: start..<end, kind: block.kind))
                index = end
                continue
            }

            if language.quotes.contains(character) {
                // A quote right after a word character is an apostrophe or a Rust lifetime, not a string.
                if character == "'", let previous, isWord(previous) {
                    index += 1
                    continue
                }
                let start = index
                index += 1
                while index < characters.count, characters[index] != character {
                    index += characters[index] == "\\" ? 2 : 1
                }
                index = min(index + 1, characters.count)
                tokens.append(SyntaxToken(range: start..<index, kind: .string))
                continue
            }

            if character.isNumber, previous.map({ !isWord($0) }) ?? true {
                let start = index
                while index < characters.count, isWord(characters[index]) || characters[index] == "." {
                    if characters[index] == ".", index + 1 < characters.count, !characters[index + 1].isNumber { break }
                    index += 1
                }
                tokens.append(SyntaxToken(range: start..<index, kind: .number))
                continue
            }

            if let prefix = language.attributePrefix, character == prefix,
               index + 1 < characters.count, isWord(characters[index + 1]) || characters[index + 1] == "[" {
                let start = index
                index += 1
                if characters[index] == "[" {
                    // Rust's `#[derive(...)]`.
                    while index < characters.count, characters[index] != "]" { index += 1 }
                    index = min(index + 1, characters.count)
                } else {
                    while index < characters.count, isWord(characters[index]) || characters[index] == "." { index += 1 }
                }
                tokens.append(SyntaxToken(range: start..<index, kind: .attribute))
                continue
            }

            if language.symbols, character == ":", index + 1 < characters.count,
               isWord(characters[index + 1]), !characters[index + 1].isNumber,
               previous != ":", previous.map({ !isWord($0) }) ?? true {
                let start = index
                index += 1
                while index < characters.count, isWord(characters[index]) { index += 1 }
                if index < characters.count, characters[index] == "?" || characters[index] == "!" { index += 1 }
                tokens.append(SyntaxToken(range: start..<index, kind: .attribute))
                continue
            }

            if language.dollarVariables, character == "$", index + 1 < characters.count,
               isWord(characters[index + 1]) || characters[index + 1] == "{" {
                let start = index
                index += 1
                if characters[index] == "{" {
                    while index < characters.count, characters[index] != "}" { index += 1 }
                    index = min(index + 1, characters.count)
                } else {
                    while index < characters.count, isWord(characters[index]) { index += 1 }
                }
                tokens.append(SyntaxToken(range: start..<index, kind: .attribute))
                continue
            }

            // Keywords that start with punctuation, such as `#include` or `!important`.
            if !isWord(character), index + 1 < characters.count, isWord(characters[index + 1]) {
                var end = index + 1
                while end < characters.count, isWord(characters[end]) { end += 1 }
                if language.keywords.contains(String(characters[index..<end])) {
                    tokens.append(SyntaxToken(range: index..<end, kind: .keyword))
                    index = end
                    continue
                }
            }

            if isWord(character) {
                let start = index
                while index < characters.count, isWord(characters[index]) { index += 1 }
                // Ruby's `defined?`.
                if index < characters.count, characters[index] == "?",
                   language.keywords.contains(String(characters[start...index])) {
                    index += 1
                }
                let word = String(characters[start..<index])
                if language.keywords.contains(word) {
                    tokens.append(SyntaxToken(range: start..<index, kind: .keyword))
                } else if language.capitalizedTypes, let first = word.first, first.isUppercase {
                    tokens.append(SyntaxToken(range: start..<index, kind: .type))
                }
                continue
            }

            index += 1
        }
        return (tokens, nil)
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
