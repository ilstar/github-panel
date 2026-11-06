import AppKit
import CoreText
import SwiftUI

/// One side of a diff row: a line and its line-number columns. The unified view has one column with the old and
/// new numbers; the split view has an old and a new column. A nil line is the blank side of a split row.
struct DiffRowColumn {
    var line: DiffDisplayLine?
    /// The line number columns; nil leaves a column blank.
    var numbers: [Int?]
    /// Opens a new-comment box on this line. Nil for lines GitHub cannot take comments on.
    var onAddComment: (() -> Void)?

    /// Whether `other` draws the same, ignoring the action.
    func drawsSame(as other: DiffRowColumn) -> Bool {
        line == other.line && numbers == other.numbers
    }
}

/// Draws a run of diff rows, with their line numbers, markers, backgrounds and code, in one AppKit view.
///
/// Building SwiftUI texts, backgrounds and hover overlays for every line was most of the cost of fast scrolling in
/// Files changed: the scroll test measured 14–16 ms a step, against 3.5 ms for a list of plain texts. One AppKit view
/// per line did not help, since the lazy list's work per view was the larger part. So each view draws a run of up
/// to ``DiffListSection/linesPerBlock`` rows: scrolling moves a few large views instead of building many small ones.
struct DiffLinesCanvas: NSViewRepresentable {
    let rows: [[DiffRowColumn]]
    var scrollActivity: ScrollActivity?

    @Environment(\.pullRequestTextSize) private var textSize
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> DiffLinesView {
        DiffLinesView()
    }

    func updateNSView(_ view: DiffLinesView, context: Context) {
        view.update(rows: rows,
                    font: PullRequestTextSize.codeFont(setting: textSize),
                    characterWidth: PullRequestTextSize.codeCharacterWidth(setting: textSize),
                    isDark: colorScheme == .dark)
        view.scrollActivity = scrollActivity
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DiffLinesView, context: Context) -> CGSize? {
        // Always answer, even without a width: returning nil sends SwiftUI to the slower Auto Layout sizing.
        var width = proposal.width ?? nsView.bounds.width
        if !width.isFinite || width <= 0 { width = max(nsView.bounds.width, 1) }
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }
}

/// The colors a diff row draws with, resolved once per appearance instead of on every draw.
struct DiffRowPalette {
    let text: CGColor
    let secondaryText: CGColor
    let emptySide: CGColor
    let divider: CGColor
    let additionHighlight: CGColor
    let deletionHighlight: CGColor
    private let backgrounds: [DiffLine.Kind: CGColor]
    private let gutters: [DiffLine.Kind: CGColor]
    private let syntax: [SyntaxKind: CGColor]

    static let light = DiffRowPalette(isDark: false)
    static let dark = DiffRowPalette(isDark: true)

    static func palette(isDark: Bool) -> DiffRowPalette { isDark ? dark : light }

    private init(isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
        func resolve(_ color: NSColor) -> CGColor {
            var resolved = color.cgColor
            appearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
            return resolved
        }
        let kinds: [DiffLine.Kind] = [.addition, .deletion, .hunk, .context, .note]
        text = resolve(.labelColor)
        secondaryText = resolve(.secondaryLabelColor)
        emptySide = resolve(NSColor(Color.secondary.opacity(0.06)))
        divider = resolve(.separatorColor)
        additionHighlight = resolve(NSColor(DiffColors.additionHighlight))
        deletionHighlight = resolve(NSColor(DiffColors.deletionHighlight))
        backgrounds = Dictionary(uniqueKeysWithValues: kinds.map { ($0, resolve(NSColor(DiffColors.background(for: $0)))) })
        gutters = Dictionary(uniqueKeysWithValues: kinds.map { ($0, resolve(NSColor(DiffColors.gutterBackground(for: $0)))) })
        let scheme: ColorScheme = isDark ? .dark : .light
        syntax = Dictionary(uniqueKeysWithValues: SyntaxKind.allCases.map {
            ($0, resolve(NSColor(DiffColors.syntaxColor($0, colorScheme: scheme))))
        })
    }

    func background(for kind: DiffLine.Kind) -> CGColor { backgrounds[kind]! }
    func gutter(for kind: DiffLine.Kind) -> CGColor { gutters[kind]! }
    func syntaxColor(_ kind: SyntaxKind) -> CGColor { syntax[kind]! }
}

/// Where each side of a diff row sits, for a given row width.
struct DiffRowGeometry: Equatable {
    struct Column: Equatable {
        /// The whole side, from its left edge to its right edge.
        let minX: CGFloat
        let maxX: CGFloat
        /// The line number columns.
        let gutterWidth: CGFloat
        /// The marker column, where the add-comment button shows.
        let markerX: CGFloat
        let markerWidth: CGFloat
        /// Where the code starts and how wide it may run before wrapping.
        let textX: CGFloat
        let textWidth: CGFloat
    }

    /// The space above and below each line.
    static let verticalPadding: CGFloat = 1
    /// The line between the two sides of the split view.
    static let dividerWidth: CGFloat = 1

    let columns: [Column]

    /// `numberColumns` holds, per side, how many line number columns it has.
    init(numberColumns: [Int], width: CGFloat, characterWidth: CGFloat) {
        let count = CGFloat(numberColumns.count)
        let sideWidth = count > 1 ? (width - Self.dividerWidth * (count - 1)) / count : width
        columns = numberColumns.enumerated().map { index, numbers in
            let x = CGFloat(index) * (sideWidth + Self.dividerWidth)
            let gutterWidth = CGFloat(numbers * DiffGutterText.columnWidth) * characterWidth
            let markerWidth = CGFloat(DiffGutterText.markerWidth) * characterWidth
            let textX = x + gutterWidth + markerWidth
            return Column(minX: x, maxX: x + sideWidth, gutterWidth: gutterWidth, markerX: x + gutterWidth,
                          markerWidth: markerWidth, textX: textX,
                          textWidth: max(characterWidth, x + sideWidth - textX))
        }
    }
}

/// The text of a diff line as Core Text draws it.
enum DiffRowText {
    /// Marks the changed words, which get a stronger fill behind them.
    static let changedKey = NSAttributedString.Key("GithubPanel.diffChanged")
    static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

    static func code(_ line: DiffDisplayLine, font: NSFont, palette: DiffRowPalette) -> NSAttributedString {
        let base = line.kind == .hunk || line.kind == .note ? palette.secondaryText : palette.text
        let text = NSMutableAttributedString()
        for segment in line.segments where !segment.text.isEmpty {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                colorKey: segment.syntax.map(palette.syntaxColor) ?? base,
            ]
            if segment.isChanged {
                attributes[changedKey] = true
            }
            text.append(NSAttributedString(string: segment.text, attributes: attributes))
        }
        if text.length == 0 {
            text.append(NSAttributedString(string: " ", attributes: [.font: font, colorKey: base]))
        }
        return text
    }

    static func gutter(numbers: [Int?], kind: DiffLine.Kind, font: NSFont,
                       palette: DiffRowPalette) -> NSAttributedString {
        NSAttributedString(string: DiffGutterText.prefix(numbers: numbers, kind: kind),
                           attributes: [.font: font, colorKey: palette.secondaryText])
    }
}

/// The AppKit view behind ``DiffLinesCanvas``.
final class DiffLinesView: NSView, NSMenuItemValidation {
    static let addCommentHelp = "Add a comment on this line"
    static let addCommentButtonSize: CGFloat = 16

    /// A side of a row: its column and, for a side with a line, its text ready for Core Text.
    private struct Side {
        let column: DiffRowColumn
        let code: NSAttributedString?
        let gutter: CTLine?
        let framesetter: CTFramesetter?
    }

    /// A row laid out for one width.
    private struct RowLayout {
        let top: CGFloat
        let height: CGFloat
        let geometry: DiffRowGeometry
        let frames: [CTFrame?]
    }

    /// A position in the code: the row, the side, and the character.
    struct TextPosition: Equatable {
        let row: Int
        let column: Int
        let index: Int
    }

    struct Selection: Equatable {
        let row: Int
        let column: Int
        let range: NSRange
    }

    /// While this says the list is scrolling, the rows do not react to the pointer. See `ScrollActivity`.
    var scrollActivity: ScrollActivity?

    private var sides: [[Side]] = []
    private var font = PullRequestTextSize.codeFont(setting: PullRequestTextSize.defaultSize)
    private var characterWidth = PullRequestTextSize.codeCharacterWidth(setting: PullRequestTextSize.defaultSize)
    private var isDark = false
    private var palette = DiffRowPalette.light

    /// The rows laid out for the last width asked for.
    private var layout: (width: CGFloat, rows: [RowLayout], height: CGFloat)?

    /// The row and side under the pointer, which shows its add-comment button.
    private(set) var hovered: (row: Int, column: Int)?
    /// The selected code, within one line at a time like the separate selectable lines before.
    private(set) var selection: Selection?
    private var selectionAnchor = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Content

    var rowCount: Int { sides.count }

    func update(rows: [[DiffRowColumn]], font: NSFont, characterWidth: CGFloat, isDark: Bool) {
        let drawsSame = font == self.font && isDark == self.isDark && rows.count == sides.count
            && zip(rows, sides).allSatisfy { row, sides in
                row.count == sides.count && zip(row, sides).allSatisfy { $0.drawsSame(as: $1.column) }
            }
        guard !drawsSame else {
            // SwiftUI hands over new actions on every update; nothing drawn changed.
            let wasCommentable = commentableSides
            sides = zip(rows, sides).map { row, sides in
                zip(row, sides).map { Side(column: $0, code: $1.code, gutter: $1.gutter, framesetter: $1.framesetter) }
            }
            if wasCommentable != commentableSides {
                updateAccessibility()
                needsDisplay = true
            }
            return
        }
        self.font = font
        self.characterWidth = characterWidth
        self.isDark = isDark
        palette = DiffRowPalette.palette(isDark: isDark)
        sides = rows.map { row in
            row.map { column in
                guard let line = column.line else {
                    return Side(column: column, code: nil, gutter: nil, framesetter: nil)
                }
                let code = DiffRowText.code(line, font: font, palette: palette)
                let gutter = DiffRowText.gutter(numbers: column.numbers, kind: line.kind, font: font, palette: palette)
                return Side(column: column, code: code, gutter: CTLineCreateWithAttributedString(gutter),
                            framesetter: CTFramesetterCreateWithAttributedString(code))
            }
        }
        layout = nil
        selection = nil
        hovered = nil
        updateAccessibility()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private var commentableSides: [[Bool]] {
        sides.map { $0.map { $0.column.onAddComment != nil } }
    }

    /// The height of all the rows when the view is `width` wide, each row as tall as its tallest side.
    func height(forWidth width: CGFloat) -> CGFloat {
        layout(forWidth: width).height
    }

    private func layout(forWidth width: CGFloat) -> (width: CGFloat, rows: [RowLayout], height: CGFloat) {
        if let layout, layout.width == width { return layout }
        let minimumLineHeight = ceil(font.ascender - font.descender + font.leading)
        var geometries: [[Int]: DiffRowGeometry] = [:]
        var top: CGFloat = 0
        let rows = sides.map { row -> RowLayout in
            let numberColumns = row.map(\.column.numbers.count)
            let geometry = geometries[numberColumns] ?? DiffRowGeometry(numberColumns: numberColumns, width: width,
                                                                       characterWidth: characterWidth)
            geometries[numberColumns] = geometry
            var textHeight = minimumLineHeight
            let frames = zip(row, geometry.columns).map { side, column -> CTFrame? in
                guard let framesetter = side.framesetter else { return nil }
                let constraint = CGSize(width: column.textWidth, height: .greatestFiniteMagnitude)
                let size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, constraint, nil)
                let height = ceil(size.height)
                textHeight = max(textHeight, height)
                let path = CGPath(rect: CGRect(x: 0, y: 0, width: column.textWidth, height: height), transform: nil)
                return CTFramesetterCreateFrame(framesetter, CFRange(), path, nil)
            }
            let height = textHeight + DiffRowGeometry.verticalPadding * 2
            defer { top += height }
            return RowLayout(top: top, height: height, geometry: geometry, frames: frames)
        }
        let result = (width: width, rows: rows, height: top)
        layout = result
        return result
    }

    /// The row at `y`, if any.
    func row(at y: CGFloat) -> Int? {
        let rows = layout(forWidth: bounds.width).rows
        var low = 0
        var high = rows.count - 1
        while low <= high {
            let mid = (low + high) / 2
            if y < rows[mid].top {
                high = mid - 1
            } else if y >= rows[mid].top + rows[mid].height {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rows = layout(forWidth: bounds.width).rows
        guard let first = row(at: max(0, dirtyRect.minY)) else { return }
        context.textMatrix = .identity
        for index in first..<rows.count {
            let row = rows[index]
            if row.top >= dirtyRect.maxY { break }
            draw(row: index, layout: row, in: context)
        }
    }

    private func draw(row index: Int, layout row: RowLayout, in context: CGContext) {
        let sides = self.sides[index]
        for (columnIndex, column) in row.geometry.columns.enumerated() {
            let side = CGRect(x: column.minX, y: row.top, width: column.maxX - column.minX, height: row.height)
            if let line = sides[columnIndex].column.line {
                context.setFillColor(palette.background(for: line.kind))
                context.fill(side)
                context.setFillColor(palette.gutter(for: line.kind))
                context.fill(CGRect(x: side.minX, y: side.minY, width: column.gutterWidth, height: side.height))
            } else {
                context.setFillColor(palette.emptySide)
                context.fill(side)
            }
            if columnIndex > 0 {
                context.setFillColor(palette.divider)
                context.fill(CGRect(x: side.minX - DiffRowGeometry.dividerWidth, y: side.minY,
                                    width: DiffRowGeometry.dividerWidth, height: side.height))
            }
        }

        for (columnIndex, column) in row.geometry.columns.enumerated() {
            guard let frame = row.frames[columnIndex] else { continue }
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(), &origins)
            let frameHeight = CTFrameGetPath(frame).boundingBox.height
            let top = row.top + DiffRowGeometry.verticalPadding

            if let gutter = sides[columnIndex].gutter, let firstOrigin = origins.first {
                drawLine(gutter, in: context, at: CGPoint(x: column.minX, y: top + frameHeight - firstOrigin.y))
            }
            for (lineIndex, ctLine) in lines.enumerated() {
                let baseline = CGPoint(x: column.textX + origins[lineIndex].x,
                                       y: top + frameHeight - origins[lineIndex].y)
                drawFills(of: ctLine, row: index, column: columnIndex, in: context, baseline: baseline)
                drawLine(ctLine, in: context, at: baseline)
            }
        }

        if let hovered, hovered.row == index, sides[hovered.column].column.onAddComment != nil {
            drawAddCommentButton(in: addCommentButtonRect(row: index, column: hovered.column))
        }
    }

    /// Draws `line` with its baseline at `baseline`, in this view's flipped coordinates.
    private func drawLine(_ line: CTLine, in context: CGContext, at baseline: CGPoint) {
        context.saveGState()
        context.translateBy(x: baseline.x, y: baseline.y)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The changed-word highlights and the selection behind one laid out line.
    private func drawFills(of line: CTLine, row: Int, column: Int, in context: CGContext, baseline: CGPoint) {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        let top = baseline.y - ascent
        let lineHeight = ascent + descent

        if let kind = sides[row][column].column.line?.kind, kind == .addition || kind == .deletion {
            context.setFillColor(kind == .addition ? palette.additionHighlight : palette.deletionHighlight)
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard attributes[DiffRowText.changedKey] != nil else { continue }
                let range = CTRunGetStringRange(run)
                let start = CTLineGetOffsetForStringIndex(line, range.location, nil)
                let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, nil)
                context.fill(CGRect(x: baseline.x + start, y: top, width: end - start, height: lineHeight))
            }
        }

        if let selection, selection.row == row, selection.column == column {
            let lineRange = CTLineGetStringRange(line)
            let start = max(selection.range.location, lineRange.location)
            let end = min(NSMaxRange(selection.range), lineRange.location + lineRange.length)
            if start < end {
                let startX = CTLineGetOffsetForStringIndex(line, start, nil)
                let endX = CTLineGetOffsetForStringIndex(line, end, nil)
                let color = window?.firstResponder === self ? NSColor.selectedTextBackgroundColor
                    : NSColor.unemphasizedSelectedTextBackgroundColor
                context.setFillColor(color.cgColor)
                context.fill(CGRect(x: baseline.x + startX, y: top, width: endX - startX, height: lineHeight))
            }
        }
    }

    // MARK: - Add-comment button

    /// The button in the marker column, like on GitHub.
    func addCommentButtonRect(row: Int, column: Int) -> CGRect {
        let row = layout(forWidth: bounds.width).rows[row]
        let geometry = row.geometry.columns[column]
        let size = Self.addCommentButtonSize
        return CGRect(x: geometry.markerX + (geometry.markerWidth - size) / 2,
                      y: row.top + DiffRowGeometry.verticalPadding, width: size, height: size)
    }

    private func drawAddCommentButton(in rect: CGRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let plus = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = plus.size
        plus.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                             width: size.width, height: size.height))
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
        toolTip = nil
    }

    /// Shows the add-comment button on the side under the pointer, unless the list is scrolling under it.
    func updateHover(at point: CGPoint) {
        guard scrollActivity?.isScrolling() != true else { return }
        let side = self.side(at: point)
        setHovered(side)
        let overButton = side.map {
            sides[$0.row][$0.column].column.onAddComment != nil
                && addCommentButtonRect(row: $0.row, column: $0.column).contains(point)
        } ?? false
        toolTip = overButton ? Self.addCommentHelp : nil
    }

    /// The side with a line under `point`.
    func side(at point: CGPoint) -> (row: Int, column: Int)? {
        guard let row = row(at: point.y) else { return nil }
        let columns = layout(forWidth: bounds.width).rows[row].geometry.columns
        guard let column = columns.firstIndex(where: { point.x >= $0.minX && point.x < $0.maxX }),
              sides[row][column].column.line != nil else { return nil }
        return (row, column)
    }

    private func setHovered(_ side: (row: Int, column: Int)?) {
        guard side?.row != hovered?.row || side?.column != hovered?.column else { return }
        let old = hovered
        hovered = side
        for row in [old?.row, side?.row].compactMap({ $0 }) {
            let layout = layout(forWidth: bounds.width).rows[row]
            setNeedsDisplay(CGRect(x: 0, y: layout.top, width: bounds.width, height: layout.height))
        }
    }

    override func resetCursorRects() {
        // One rect per side, not per row: the code starts at the same x on every row.
        let rows = layout(forWidth: bounds.width).rows
        guard let geometry = rows.first?.geometry else { return }
        for column in geometry.columns {
            addCursorRect(CGRect(x: column.textX, y: 0, width: column.maxX - column.textX, height: bounds.height),
                          cursor: .iBeam)
        }
    }

    // MARK: - Selection

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let side = side(at: point), let action = sides[side.row][side.column].column.onAddComment,
           addCommentButtonRect(row: side.row, column: side.column).contains(point) {
            action()
            return
        }
        guard let position = textPosition(at: point), let text = sides[position.row][position.column].code else {
            super.mouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        switch event.clickCount {
        case 1:
            selectionAnchor = position.index
            setSelection(Selection(row: position.row, column: position.column,
                                   range: NSRange(location: position.index, length: 0)))
        case 2:
            let range = text.doubleClick(at: min(position.index, max(0, text.length - 1)))
            setSelection(Selection(row: position.row, column: position.column, range: range))
        default:
            setSelection(Selection(row: position.row, column: position.column,
                                   range: NSRange(location: 0, length: text.length)))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let selection else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = stringIndex(at: point, row: selection.row, column: selection.column)
        setSelection(Selection(row: selection.row, column: selection.column,
                               range: NSRange(location: min(selectionAnchor, index),
                                              length: abs(index - selectionAnchor))))
    }

    override func resignFirstResponder() -> Bool {
        setSelection(nil)
        return super.resignFirstResponder()
    }

    func setSelection(_ newSelection: Selection?) {
        guard newSelection != selection else { return }
        selection = newSelection
        needsDisplay = true
    }

    /// The selected code, or nil when nothing is selected.
    var selectedText: String? {
        guard let selection, selection.range.length > 0,
              let text = sides[selection.row][selection.column].code else { return nil }
        return (text.string as NSString).substring(with: selection.range)
    }

    @objc func copy(_ sender: Any?) {
        copy(to: .general)
    }

    func copy(to pasteboard: NSPasteboard) {
        guard let selectedText else { return }
        pasteboard.clearContents()
        pasteboard.setString(selectedText, forType: .string)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? selectedText != nil : false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard selectedText != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
        return menu
    }

    /// The row, side and character under `point`, if it is over code.
    func textPosition(at point: CGPoint) -> TextPosition? {
        guard let row = row(at: point.y) else { return nil }
        let columns = layout(forWidth: bounds.width).rows[row].geometry.columns
        guard let column = columns.firstIndex(where: { point.x >= $0.textX && point.x < $0.maxX }),
              sides[row][column].code != nil else { return nil }
        return TextPosition(row: row, column: column, index: stringIndex(at: point, row: row, column: column))
    }

    /// The character boundary nearest `point` in one side's code.
    func stringIndex(at point: CGPoint, row: Int, column: Int) -> Int {
        let layout = layout(forWidth: bounds.width).rows[row]
        guard let frame = layout.frames[column] else { return 0 }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return 0 }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)
        let frameHeight = CTFrameGetPath(frame).boundingBox.height
        let y = point.y - layout.top - DiffRowGeometry.verticalPadding
        // The first line whose bottom is below the point, else the last line.
        var lineIndex = lines.count - 1
        for (index, line) in lines.enumerated() {
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, nil, &descent, nil)
            if y < frameHeight - origins[index].y + descent {
                lineIndex = index
                break
            }
        }
        let line = lines[lineIndex]
        let x = point.x - layout.geometry.columns[column].textX - origins[lineIndex].x
        let lineRange = CTLineGetStringRange(line)
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        let end = lineRange.location + lineRange.length
        return index == kCFNotFound ? end : min(max(index, lineRange.location), end)
    }

    // MARK: - Accessibility

    /// Reads the lines in order, with a custom action for each line that takes comments.
    private func updateAccessibility() {
        setAccessibilityLabel(sides.map { row in
            row.compactMap { side in
                side.column.line.map { line in
                    (side.column.numbers.compactMap { $0 }.last.map { "Line \($0): " } ?? "") + line.text
                }
            }
            .joined(separator: "; ")
        }
        .joined(separator: "\n"))
        setAccessibilityCustomActions(sides.indices.flatMap { row in
            sides[row].indices.compactMap { column -> NSAccessibilityCustomAction? in
                guard let line = sides[row][column].column.line, sides[row][column].column.onAddComment != nil
                else { return nil }
                let number = sides[row][column].column.numbers.compactMap { $0 }.last.map { " \($0)" } ?? ""
                // Looks up the current action, since SwiftUI hands over new ones on every update.
                return NSAccessibilityCustomAction(name: "Comment on line\(number): \(line.text)") { [weak self] in
                    guard let self, row < self.sides.count, column < self.sides[row].count,
                          let action = self.sides[row][column].column.onAddComment else { return false }
                    action()
                    return true
                }
            }
        })
    }
}
