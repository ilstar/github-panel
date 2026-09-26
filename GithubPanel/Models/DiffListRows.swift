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
    /// The review threads under the line at `index`, and whether the new-comment box is open there.
    case lineComments(filename: String, index: Int, threads: [ReviewThread], composing: DiffCommentAnchor?)
    /// Threads with no line in the diff to sit under, such as outdated ones.
    case unplacedThreads(filename: String, threads: [ReviewThread])
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
        case let .lineComments(filename, index, _, _): return "\(filename)#c\(index)"
        case let .unplacedThreads(filename, _): return "\(filename)#unplaced"
        case let .footer(filename): return "\(filename)#footer"
        }
    }

    /// Builds the rows for `files`. `presentation` returns nil for a file with no diff lines.
    /// `composing` is the line with an open new-comment box.
    static func rows(files: [PullRequestFile],
                     collapsed: Set<String>,
                     mode: DiffViewMode,
                     hideWhitespace: Bool,
                     threads: (String) -> ReviewThreadIndex = { _ in ReviewThreadIndex(threads: []) },
                     composing: DiffCommentAnchor? = nil,
                     presentation: (String) -> DiffPresentation?) -> [DiffListRow] {
        var rows: [DiffListRow] = []
        for file in files {
            rows.append(.header(file))
            guard !collapsed.contains(file.filename) else { continue }
            let name = file.filename
            let index = threads(name)
            func addComments(at lineIndex: Int, threads: [ReviewThread], anchors: [DiffCommentAnchor?]) {
                let open = composing.flatMap { anchors.contains($0) ? $0 : nil }
                guard !threads.isEmpty || open != nil else { return }
                rows.append(.lineComments(filename: name, index: lineIndex, threads: threads, composing: open))
            }
            if let presentation = presentation(name) {
                if hideWhitespace && !presentation.hasChanges {
                    rows.append(.message(filename: name, text: "Only whitespace changed."))
                } else {
                    switch mode {
                    case .unified:
                        for (lineIndex, line) in presentation.unified.enumerated() {
                            rows.append(.unified(filename: name, index: lineIndex, line: line))
                            addComments(at: lineIndex,
                                        threads: index.threads(for: line, path: name),
                                        anchors: [DiffCommentAnchor.unified(path: name, line: line)])
                        }
                    case .split:
                        for (rowIndex, row) in presentation.split.enumerated() {
                            rows.append(.split(filename: name, index: rowIndex, row: row))
                            guard case let .pair(left, right) = row else { continue }
                            // A context line sits on both sides; list its threads once.
                            let lines = left == right ? [left] : [left, right]
                            addComments(at: rowIndex,
                                        threads: lines.compactMap { $0 }.flatMap { index.threads(for: $0, path: name) },
                                        anchors: [DiffCommentAnchor.split(path: name, line: left, side: .left),
                                                  DiffCommentAnchor.split(path: name, line: right, side: .right)])
                        }
                    }
                }
                let unplaced = index.unplacedThreads(in: presentation.unified, path: name)
                if !unplaced.isEmpty {
                    rows.append(.unplacedThreads(filename: name, threads: unplaced))
                }
            } else {
                rows.append(.noDiff(file))
                if !index.threads.isEmpty {
                    rows.append(.unplacedThreads(filename: name, threads: index.threads))
                }
            }
            rows.append(.footer(filename: name))
        }
        return rows
    }
}

/// One file in the Files changed list: its header and the rows under it. The list pins each section's header to
/// the top while its rows scroll past, so the file's path stays on screen until the next file's header takes over.
struct DiffListSection: Identifiable, Equatable {
    let file: PullRequestFile
    /// The rows after the header; empty for a folded file.
    let rows: [DiffListRow]

    var id: String { file.filename }

    /// Splits `rows` at each header.
    static func sections(_ rows: [DiffListRow]) -> [DiffListSection] {
        var sections: [DiffListSection] = []
        var file: PullRequestFile?
        var fileRows: [DiffListRow] = []
        for row in rows {
            if case let .header(next) = row {
                if let file { sections.append(DiffListSection(file: file, rows: fileRows)) }
                file = next
                fileRows = []
            } else {
                fileRows.append(row)
            }
        }
        if let file { sections.append(DiffListSection(file: file, rows: fileRows)) }
        return sections
    }
}
