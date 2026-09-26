import Foundation

/// One row of the Files changed list. Every file's header, diff lines, and footer are separate rows in one
/// lazy list, so scrolling only builds the rows on screen instead of a whole file at a time.
enum DiffListRow: Identifiable, Equatable {
    case header(PullRequestFile)
    case unified(filename: String, index: Int, line: DiffDisplayLine)
    case split(filename: String, index: Int, row: SplitDiffRow)
    /// A note in place of the diff, such as a whitespace-only change.
    case message(filename: String, text: String)
    /// A binary file or a diff too large for GitHub to return.
    case noDiff(PullRequestFile)
    /// Closes the file's card.
    case footer(filename: String)

    var id: String {
        switch self {
        // The header uses the bare filename so the file tree can scroll to it.
        case let .header(file): return file.filename
        case let .unified(filename, index, _): return "\(filename)#u\(index)"
        case let .split(filename, index, _): return "\(filename)#s\(index)"
        case let .message(filename, _): return "\(filename)#message"
        case let .noDiff(file): return "\(file.filename)#none"
        case let .footer(filename): return "\(filename)#footer"
        }
    }

    /// Builds the rows for `files`. `presentation` returns nil for a file with no diff lines.
    static func rows(files: [PullRequestFile],
                     collapsed: Set<String>,
                     mode: DiffViewMode,
                     hideWhitespace: Bool,
                     presentation: (String) -> DiffPresentation?) -> [DiffListRow] {
        var rows: [DiffListRow] = []
        for file in files {
            rows.append(.header(file))
            guard !collapsed.contains(file.filename) else { continue }
            let name = file.filename
            if let presentation = presentation(name) {
                if hideWhitespace && !presentation.hasChanges {
                    rows.append(.message(filename: name, text: "Only whitespace changed."))
                } else {
                    switch mode {
                    case .unified:
                        rows += presentation.unified.enumerated().map { .unified(filename: name, index: $0, line: $1) }
                    case .split:
                        rows += presentation.split.enumerated().map { .split(filename: name, index: $0, row: $1) }
                    }
                }
            } else {
                rows.append(.noDiff(file))
            }
            rows.append(.footer(filename: name))
        }
        return rows
    }
}
