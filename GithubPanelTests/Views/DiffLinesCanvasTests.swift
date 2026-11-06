import XCTest
import AppKit
@testable import GithubPanel

@MainActor
final class DiffLinesCanvasTests: XCTestCase {
    private let font = PullRequestTextSize.codeFont(setting: PullRequestTextSize.defaultSize)
    private let characterWidth = PullRequestTextSize.codeCharacterWidth(setting: PullRequestTextSize.defaultSize)
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func line(_ text: String, kind: DiffLine.Kind = .context, number: Int = 1,
                      changed: Bool = false) -> DiffDisplayLine {
        DiffDisplayLine(kind: kind, oldLineNumber: kind == .addition ? nil : number,
                        newLineNumber: kind == .deletion ? nil : number,
                        segments: [DiffSegment(text: text, isChanged: changed)])
    }

    /// A view in a window, `width` wide and as tall as its rows.
    private func view(_ rows: [[DiffRowColumn]], width: CGFloat = 800) -> DiffLinesView {
        let view = DiffLinesView()
        view.update(rows: rows, font: font, characterWidth: characterWidth, isDark: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.height(forWidth: width))
        window.contentView?.addSubview(view)
        return view
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    // MARK: - Text

    func testCodeMarksOnlyChangedWords() {
        let line = DiffDisplayLine(kind: .addition, oldLineNumber: nil, newLineNumber: 1, segments: [
            DiffSegment(text: "hello ", isChanged: false),
            DiffSegment(text: "claude", isChanged: true),
        ])

        let text = DiffRowText.code(line, font: font, palette: .light)

        XCTAssertEqual(text.string, "hello claude")
        var changed: [String] = []
        text.enumerateAttribute(DiffRowText.changedKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if value != nil { changed.append((text.string as NSString).substring(with: range)) }
        }
        XCTAssertEqual(changed, ["claude"])
    }

    func testCodeColorsSyntaxAndDimsHunkHeaders() {
        let code = DiffDisplayLine(kind: .context, oldLineNumber: 1, newLineNumber: 1, segments: [
            DiffSegment(text: "let", isChanged: false, syntax: .keyword),
            DiffSegment(text: " a", isChanged: false),
        ])
        let hunk = line("@@ -1 +1 @@", kind: .hunk)
        func color(_ text: NSAttributedString, at index: Int) -> CGColor {
            text.attribute(DiffRowText.colorKey, at: index, effectiveRange: nil) as! CGColor
        }

        let colored = DiffRowText.code(code, font: font, palette: .light)

        XCTAssertEqual(color(colored, at: 0), DiffRowPalette.light.syntaxColor(.keyword))
        XCTAssertEqual(color(colored, at: 4), DiffRowPalette.light.text)
        XCTAssertEqual(color(DiffRowText.code(hunk, font: font, palette: .light), at: 0), DiffRowPalette.light.secondaryText)
    }

    func testEmptyLinesStayVisible() {
        XCTAssertEqual(DiffRowText.code(line(""), font: font, palette: .light).string, " ")
    }

    func testPalettesFollowTheColorScheme() {
        XCTAssertNotEqual(DiffRowPalette.light.text, DiffRowPalette.dark.text)
        XCTAssertNotEqual(DiffRowPalette.light.syntaxColor(.string), DiffRowPalette.dark.syntaxColor(.string))
    }

    // MARK: - Layout

    func testUnifiedRowHasBothNumberColumnsBeforeTheCode() {
        let geometry = DiffRowGeometry(numberColumns: [2], width: 800, characterWidth: 10)

        XCTAssertEqual(geometry.columns.count, 1)
        XCTAssertEqual(geometry.columns[0].gutterWidth, CGFloat(2 * DiffGutterText.columnWidth) * 10)
        XCTAssertEqual(geometry.columns[0].textX, CGFloat(2 * DiffGutterText.columnWidth + DiffGutterText.markerWidth) * 10)
        XCTAssertEqual(geometry.columns[0].textWidth, 800 - geometry.columns[0].textX)
    }

    func testSplitRowHalvesTheWidthAroundTheDivider() {
        let geometry = DiffRowGeometry(numberColumns: [1, 1], width: 801, characterWidth: 10)

        XCTAssertEqual(geometry.columns.map(\.minX), [0, 401])
        XCTAssertEqual(geometry.columns.map(\.maxX), [400, 801])
        XCTAssertEqual(geometry.columns[1].textX, 401 + CGFloat(DiffGutterText.columnWidth + DiffGutterText.markerWidth) * 10)
    }

    func testRowsStackAndLongLinesWrap() {
        let short = DiffLineColumns.unified(line("short"))
        let long = DiffLineColumns.unified(line(String(repeating: "word ", count: 60)))
        let view = view([short, long, short], width: 400)

        let lineHeight = view.height(forWidth: 4000) / 3
        XCTAssertGreaterThan(view.height(forWidth: 400), lineHeight * 4, "The long line wraps onto more lines")
        XCTAssertEqual(view.row(at: 1), 0)
        XCTAssertEqual(view.row(at: lineHeight + 1), 1)
        XCTAssertEqual(view.row(at: view.bounds.height - 1), 2)
        XCTAssertNil(view.row(at: view.bounds.height + 1))
    }

    func testSplitRowIsAsTallAsItsTallerSide() {
        let longLeft = DiffLineColumns.split(.pair(left: line(String(repeating: "word ", count: 60), kind: .deletion),
                                                   right: line("b", kind: .addition)))
        let shortBoth = DiffLineColumns.split(.pair(left: line("a", kind: .deletion), right: line("b", kind: .addition)))

        XCTAssertGreaterThan(view([longLeft]).height(forWidth: 800), view([shortBoth]).height(forWidth: 800) * 2)
    }

    // MARK: - Pointer

    func testAddCommentButtonRunsTheLatestAction() throws {
        var calls: [String] = []
        let row = line("let a = 1", kind: .addition)
        let view = view([DiffLineColumns.unified(row, onAddComment: { calls.append("old") })])
        // SwiftUI hands over a new action on every update without changing what is drawn.
        view.update(rows: [DiffLineColumns.unified(row, onAddComment: { calls.append("new") })], font: font,
                    characterWidth: characterWidth, isDark: false)
        let button = view.addCommentButtonRect(row: 0, column: 0)

        view.updateHover(at: CGPoint(x: button.midX, y: button.midY))
        XCTAssertEqual(view.toolTip, DiffLinesView.addCommentHelp)
        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: button.midX, y: button.midY), in: view))

        XCTAssertEqual(calls, ["new"])
    }

    func testOnlyTheSideUnderThePointerOffersAComment() {
        let row = DiffLineColumns.split(.pair(left: nil, right: line("b", kind: .addition)),
                                        onAddLeftComment: {}, onAddRightComment: {})
        let view = view([row])

        view.updateHover(at: CGPoint(x: 10, y: 5))
        XCTAssertNil(view.hovered, "The blank left side takes no comment")
        view.updateHover(at: CGPoint(x: 700, y: 5))
        XCTAssertEqual(view.hovered?.column, 1)
    }

    func testRowsIgnoreThePointerWhileTheListScrolls() {
        let view = view([DiffLineColumns.unified(line("a"), onAddComment: {})])
        let activity = ScrollActivity()
        view.scrollActivity = activity

        activity.noteMovement()
        view.updateHover(at: CGPoint(x: 10, y: 5))

        XCTAssertNil(view.hovered)
    }

    // MARK: - Selection

    func testDoubleClickSelectsAWordAndCopyPutsItOnThePasteboard() throws {
        let view = view([DiffLineColumns.unified(line("let value = compute()"))])
        let textX = DiffRowGeometry(numberColumns: [2], width: 800, characterWidth: characterWidth).columns[0].textX
        let point = CGPoint(x: textX + characterWidth * 6, y: 5)

        view.mouseDown(with: mouse(.leftMouseDown, at: point, in: view, clicks: 2))
        XCTAssertEqual(view.selectedText, "value")

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DiffLinesCanvasTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        view.copy(to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "value")
    }

    func testDragSelectsCodeWithinTheLine() {
        let view = view([DiffLineColumns.unified(line("let value = compute()"))])
        let textX = DiffRowGeometry(numberColumns: [2], width: 800, characterWidth: characterWidth).columns[0].textX

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: textX + 1, y: 5), in: view))
        view.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: textX + characterWidth * 3 + 1, y: 5), in: view))

        XCTAssertEqual(view.selectedText, "let")
    }

    func testClickOnTheGutterSelectsNothing() {
        let view = view([DiffLineColumns.unified(line("let a"))])

        view.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 2, y: 5), in: view, clicks: 3))

        XCTAssertNil(view.selectedText)
    }

    func testNewLinesClearTheSelection() {
        let view = view([DiffLineColumns.unified(line("let a"))])
        view.setSelection(.init(row: 0, column: 0, range: NSRange(location: 0, length: 3)))
        XCTAssertEqual(view.selectedText, "let")

        view.update(rows: [DiffLineColumns.unified(line("var b"))], font: font, characterWidth: characterWidth,
                    isDark: false)

        XCTAssertNil(view.selectedText)
    }
}
