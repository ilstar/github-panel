import XCTest
@testable import GithubPanel

final class SyntaxHighlighterTests: XCTestCase {
    /// Each token's text and kind, for readable assertions.
    private func colored(_ line: String, _ language: SyntaxLanguage) -> [String: SyntaxKind] {
        let characters = Array(line)
        var result: [String: SyntaxKind] = [:]
        for token in SyntaxHighlighter.tokens(line, language: language) {
            result[String(characters[token.range])] = token.kind
        }
        return result
    }

    func testPicksTheLanguageFromTheFilename() {
        XCTAssertEqual(SyntaxLanguage(filename: "Sources/App.swift"), .swift)
        XCTAssertEqual(SyntaxLanguage(filename: "app/models/user.rb"), .ruby)
        XCTAssertEqual(SyntaxLanguage(filename: "web/index.TSX"), .javaScript)
        XCTAssertEqual(SyntaxLanguage(filename: "Gemfile"), .ruby)
        XCTAssertEqual(SyntaxLanguage(filename: "docker/Dockerfile"), .shell)
        XCTAssertNil(SyntaxLanguage(filename: "README"))
        XCTAssertNil(SyntaxLanguage(filename: "image.png"))
    }

    func testColorsSwiftKeywordsStringsNumbersTypesAndComments() {
        let tokens = colored("@MainActor let name: String = \"hi\" + 42 // greet", .swift)

        XCTAssertEqual(tokens, [
            "@MainActor": .attribute,
            "let": .keyword,
            "String": .type,
            "\"hi\"": .string,
            "42": .number,
            "// greet": .comment
        ])
    }

    func testSkipsEscapedQuotesInsideStrings() {
        XCTAssertEqual(colored(#"x = "a \"b\" c""#, .python), [#""a \"b\" c""#: .string])
    }

    func testDoesNotTreatApostrophesAsStrings() {
        XCTAssertEqual(colored("# don't", .ruby), ["# don't": .comment])
        XCTAssertEqual(colored("key: it's fine", .yaml), [:])
    }

    func testColorsRubySymbolsButNotScopes() {
        XCTAssertEqual(colored("Foo::Bar.call(:name)", .ruby), ["Foo": .type, "Bar": .type, ":name": .attribute])
    }

    func testColorsKeywordsThatStartWithPunctuation() {
        XCTAssertEqual(colored("#include <stdio.h>", .cFamily), ["#include": .keyword])
        XCTAssertEqual(colored("if defined?(x)", .ruby), ["if": .keyword, "defined?": .keyword])
    }

    func testDoesNotColorWordsInsideIdentifiers() {
        XCTAssertEqual(colored("letter = value2", .swift), [:])
    }

    func testCarriesBlockCommentsAcrossLines() {
        let first = SyntaxHighlighter.tokens("x /* start", language: .swift, state: nil)
        XCTAssertEqual(first.tokens, [SyntaxToken(range: 2..<10, kind: .comment)])
        XCTAssertNotNil(first.state)

        let middle = SyntaxHighlighter.tokens("still", language: .swift, state: first.state)
        XCTAssertEqual(middle.tokens, [SyntaxToken(range: 0..<5, kind: .comment)])

        let last = SyntaxHighlighter.tokens("end */ let", language: .swift, state: middle.state)
        XCTAssertEqual(last.tokens, [SyntaxToken(range: 0..<6, kind: .comment), SyntaxToken(range: 7..<10, kind: .keyword)])
        XCTAssertNil(last.state)
    }

    func testPresentationColorsCodeAndKeepsWordHighlights() {
        let patch = "@@ -1 +1 @@\n-let a = 1\n+let a = 10"

        let lines = DiffPresentation(lines: DiffParser.parse(patch), hideWhitespace: false, language: .swift).unified

        XCTAssertEqual(lines[2].segments, [
            DiffSegment(text: "let", isChanged: false, syntax: .keyword),
            DiffSegment(text: " a = ", isChanged: false),
            DiffSegment(text: "10", isChanged: true, syntax: .number)
        ])
        XCTAssertEqual(lines[2].text, "let a = 10")
        XCTAssertEqual(lines[0].segments, [DiffSegment(text: "@@ -1 +1 @@", isChanged: false)])
    }

    func testPresentationTracksTheOldAndNewSidesSeparately() {
        // The deletion opens a comment only in the old file, so the addition after it stays code.
        let patch = "@@ -1,2 +1,2 @@\n-/* old\n+let a = 1\n x */"

        let lines = DiffPresentation(lines: DiffParser.parse(patch), hideWhitespace: false, language: .swift).unified

        XCTAssertEqual(lines[2].segments.first?.syntax, .keyword)
    }

    func testPresentationWithoutALanguageStaysPlain() {
        let lines = DiffPresentation(lines: DiffParser.parse("@@ -0,0 +1 @@\n+let a = 1"), hideWhitespace: false).unified

        XCTAssertEqual(lines[1].segments, [DiffSegment(text: "let a = 1", isChanged: false)])
    }

    func testColoringSplitsSegmentsAtTokenEdges() {
        let segments = [DiffSegment(text: "ab", isChanged: false), DiffSegment(text: "cd", isChanged: true)]

        let result = DiffPresentation.coloring(segments, with: [SyntaxToken(range: 1..<3, kind: .string)])

        XCTAssertEqual(result, [
            DiffSegment(text: "a", isChanged: false),
            DiffSegment(text: "b", isChanged: false, syntax: .string),
            DiffSegment(text: "c", isChanged: true, syntax: .string),
            DiffSegment(text: "d", isChanged: true)
        ])
    }
}
