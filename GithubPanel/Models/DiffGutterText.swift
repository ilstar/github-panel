import Foundation

/// The line numbers and +/- marker in front of a diff line, as one monospaced string.
enum DiffGutterText {
    /// Characters per line number column: up to six digits, right-aligned, then a space.
    static let columnWidth = 7
    /// Characters for the marker column: the marker with a space on each side.
    static let markerWidth = 3

    static func prefix(numbers: [Int?], kind: DiffLine.Kind) -> String {
        let columns = numbers.map { number -> String in
            let digits = number.map(String.init) ?? ""
            return String(repeating: " ", count: max(0, columnWidth - 1 - digits.count)) + digits + " "
        }
        return columns.joined() + " \(marker(kind)) "
    }

    static func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .hunk, .context, .note: return " "
        }
    }
}
