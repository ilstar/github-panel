import SwiftUI
import AppKit

enum DiffViewMode: String, CaseIterable, Identifiable {
    case unified
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unified: return "Unified"
        case .split: return "Split"
        }
    }
}

struct PullRequestFilesView: View {
    static let viewModeDefaultsKey = "diffViewMode"
    static let hideWhitespaceDefaultsKey = "diffHideWhitespace"
    static let showsFileTreeDefaultsKey = "diffShowsFileTree"

    @ObservedObject var viewModel: PullRequestDetailViewModel
    let files: [PullRequestFile]
    let filesURL: URL

    @AppStorage(viewModeDefaultsKey) private var mode: DiffViewMode = .unified
    @AppStorage(hideWhitespaceDefaultsKey) private var hideWhitespace = false
    @AppStorage(showsFileTreeDefaultsKey) private var showsFileTree = true
    @State private var collapsed: Set<String> = []
    @State private var didCollapseViewedFiles = false
    @State private var collapsedDirectories: Set<String> = []
    @State private var searchText = ""
    @State private var selectedFile: String?
    @State private var scrollRequest: ScrollRequest?

    private struct ScrollRequest: Equatable {
        let id = UUID()
        let filename: String
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            HStack(spacing: 0) {
                if showsFileTree {
                    fileTree
                        .frame(width: 260)
                    Divider()
                }
                diffList
            }
        }
        .onAppear {
            // Viewed files start folded, like on GitHub.
            guard !didCollapseViewedFiles else { return }
            collapsed = viewModel.viewedFiles
            didCollapseViewedFiles = true
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                showsFileTree.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(showsFileTree ? "Hide file tree" : "Show file tree")

            Text("\(viewedCount) / \(files.count) files viewed")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Toggle("Hide whitespace", isOn: $hideWhitespace)
                .toggleStyle(.checkbox)

            Picker("", selection: $mode) {
                ForEach(DiffViewMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button("Expand All") { collapsed = [] }
                .disabled(collapsed.isEmpty)
            Button("Collapse All") { collapsed = Set(files.map(\.filename)) }
                .disabled(collapsed.count == files.count)
        }
    }

    private var viewedCount: Int {
        files.filter { viewModel.viewedFiles.contains($0.filename) }.count
    }

    // MARK: - File tree

    private var treeRows: [FileTreeRow] {
        FileTree.rows(for: files.map(\.filename).filter { FileTree.matches($0, query: searchText) })
    }

    /// The files that match the search, in the same order as the tree.
    private var visibleFiles: [PullRequestFile] {
        let byName = Dictionary(files.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        return treeRows.filter { $0.kind == .file }.compactMap { byName[$0.id] }
    }

    private var fileTree: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter files", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
            .padding(8)

            let rows = FileTree.visibleRows(treeRows, collapsed: collapsedDirectories)
            if rows.isEmpty {
                Text(files.isEmpty ? "No files changed." : "No matching files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            treeRow(row)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func treeRow(_ row: FileTreeRow) -> some View {
        let isSelected = row.kind == .file && row.id == selectedFile
        return HStack(spacing: 4) {
            switch row.kind {
            case .directory:
                let isCollapsed = collapsedDirectories.contains(row.id)
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Image(systemName: isCollapsed ? "folder" : "folder.fill")
                    .foregroundStyle(.secondary)
            case .file:
                Color.clear.frame(width: 12, height: 1)
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }

            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if row.kind == .file, viewModel.viewedFiles.contains(row.id) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Viewed")
            }
        }
        .font(.callout)
        .padding(.leading, CGFloat(row.depth) * 14 + 4)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            switch row.kind {
            case .directory:
                if collapsedDirectories.contains(row.id) {
                    collapsedDirectories.remove(row.id)
                } else {
                    collapsedDirectories.insert(row.id)
                }
            case .file:
                selectedFile = row.id
                scrollRequest = ScrollRequest(filename: row.id)
            }
        }
        .contextMenu {
            Button("Copy Path") { PullRequestFileHeader.copyPath(row.id) }
        }
        .help(row.id)
    }

    // MARK: - Diffs

    private var diffList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // One lazy row per diff line, so only the lines on screen are built.
                LazyVStack(alignment: .leading, spacing: 0) {
                    if files.isEmpty {
                        Text("No files changed.")
                            .foregroundStyle(.secondary)
                    } else if visibleFiles.isEmpty {
                        Text("No files match “\(searchText)”.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(diffRows) { row in
                        diffRow(row)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .padding(.top, 8)
            }
            .onChange(of: scrollRequest) { request in
                guard let request else { return }
                proxy.scrollTo(request.filename, anchor: .top)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var diffRows: [DiffListRow] {
        DiffListRow.rows(files: visibleFiles,
                         collapsed: collapsed,
                         mode: mode,
                         hideWhitespace: hideWhitespace) { filename in
            guard let lines = viewModel.diffLines[filename], !lines.isEmpty else { return nil }
            return viewModel.presentation(for: filename, hideWhitespace: hideWhitespace)
        }
    }

    @ViewBuilder
    private func diffRow(_ row: DiffListRow) -> some View {
        switch row {
        case let .header(file):
            fileHeader(file)
                .padding(.top, 16)
        case let .unified(_, _, line):
            DiffLineRow(line: line)
                .fileCardEdges(.middle)
        case let .split(_, _, row):
            SplitDiffRowView(row: row)
                .fileCardEdges(.middle)
        case let .message(_, text):
            fileMessage(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fileCardEdges(.middle)
        case let .noDiff(file):
            HStack(spacing: 4) {
                Text(file.patch == nil ? "Binary file or diff too large to show here." : "No changes to show.")
                Link("View on GitHub", destination: filesURL)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fileCardEdges(.middle)
        case .footer:
            Color.clear
                .frame(height: FileCardEdges.cornerRadius)
                .fileCardEdges(.bottom)
        }
    }

    private func fileHeader(_ file: PullRequestFile) -> some View {
        let isCollapsed = collapsed.contains(file.filename)
        let isViewed = viewModel.viewedFiles.contains(file.filename)
        return PullRequestFileHeader(file: file,
                                     isCollapsed: isCollapsed,
                                     isViewed: isViewed,
                                     onToggle: {
                                         if isCollapsed {
                                             collapsed.remove(file.filename)
                                         } else {
                                             collapsed.insert(file.filename)
                                         }
                                     },
                                     onSetViewed: { viewed in
                                         // Marking a file viewed folds it; unmarking unfolds it.
                                         if viewed {
                                             collapsed.insert(file.filename)
                                         } else {
                                             collapsed.remove(file.filename)
                                         }
                                         Task { await viewModel.setViewed(viewed, filename: file.filename) }
                                     })
            // A folded file is a whole card; an open one continues into its diff rows.
            .fileCardEdges(isCollapsed ? .all : .top)
    }

    private func fileMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
    }
}

struct PullRequestFileHeader: View {
    let file: PullRequestFile
    let isCollapsed: Bool
    let isViewed: Bool
    let onToggle: () -> Void
    let onSetViewed: (Bool) -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Expand file" : "Collapse file")

            Text(Self.statusLabel(file.status))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                .foregroundStyle(.secondary)

            Text(Self.displayName(file))
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(Self.displayName(file))

            Button {
                Self.copyPath(file.filename)
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy file path")

            Spacer(minLength: 8)

            Text("+\(file.additions)")
                .foregroundStyle(DiffColors.additionText)
            Text("−\(file.deletions)")
                .foregroundStyle(DiffColors.deletionText)

            Toggle("Viewed", isOn: Binding(get: { isViewed }, set: onSetViewed))
                .toggleStyle(.checkbox)
                .padding(.leading, 4)
        }
        .font(.callout.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    static func displayName(_ file: PullRequestFile) -> String {
        if let previous = file.previousFilename, previous != file.filename {
            return "\(previous) → \(file.filename)"
        }
        return file.filename
    }

    static func statusLabel(_ status: PullRequestFile.Status) -> String {
        switch status {
        case .added: return "ADDED"
        case .removed: return "DELETED"
        case .modified, .changed: return "MODIFIED"
        case .renamed: return "RENAMED"
        case .copied: return "COPIED"
        case .unchanged: return "UNCHANGED"
        }
    }

    static func copyPath(_ path: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }
}

/// Draws one row's share of a file's rounded card: the header is the top, diff lines are the sides, and the
/// footer is the bottom. The rows are separate so the diff list can build them lazily.
struct FileCardEdges: Shape {
    enum Part {
        case all
        case top
        case middle
        case bottom
    }

    static let cornerRadius: CGFloat = 8

    let part: Part

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: 0.5, dy: 0)
        let radius = Self.cornerRadius
        var path = Path()
        switch part {
        case .all:
            path.addRoundedRect(in: rect.insetBy(dx: 0, dy: 0.5), cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        case .top:
            // Closed along the bottom, which draws the line between the header and the diff.
            let rect = rect.insetBy(dx: 0, dy: 0.5)
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        case .middle:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottom:
            let rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 0.5)
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX + radius, y: rect.maxY), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY - radius), radius: radius)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        return path
    }
}

extension View {
    /// Clips the row to its part of the file card and draws that part of the border.
    @ViewBuilder
    func fileCardEdges(_ part: FileCardEdges.Part) -> some View {
        let border = FileCardEdges(part: part).stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        switch part {
        case .all:
            clipShape(RoundedRectangle(cornerRadius: FileCardEdges.cornerRadius, style: .continuous)).overlay(border)
        case .top:
            clipShape(FileCardEdges(part: .top)).overlay(border)
        case .middle, .bottom:
            // Only the header has corners to clip; the diff rows are square, so skip the mask.
            overlay(border)
        }
    }
}

/// One line of the unified view.
struct DiffLineRow: View {
    let line: DiffDisplayLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            DiffGutter(number: line.oldLineNumber, kind: line.kind)
            DiffGutter(number: line.newLineNumber, kind: line.kind)
            DiffLineContent(line: line)
        }
        .font(.system(size: 12, design: .monospaced))
        .background(DiffColors.background(for: line.kind))
    }
}

/// One row of the split view: the old line on the left and the new line on the right.
struct SplitDiffRowView: View {
    let row: SplitDiffRow

    var body: some View {
        switch row {
        case let .full(line):
            HStack(spacing: 0) {
                Color.clear.frame(width: 56)
                DiffLineContent(line: line)
            }
            .font(.system(size: 12, design: .monospaced))
            .background(DiffColors.background(for: line.kind))
        case let .pair(left, right):
            HStack(alignment: .top, spacing: 0) {
                half(left, number: left?.oldLineNumber)
                Divider()
                half(right, number: right?.newLineNumber)
            }
            .fixedSize(horizontal: false, vertical: true)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    @ViewBuilder
    private func half(_ line: DiffDisplayLine?, number: Int?) -> some View {
        Group {
            if let line {
                HStack(alignment: .top, spacing: 0) {
                    DiffGutter(number: number, kind: line.kind)
                    DiffLineContent(line: line)
                }
                .background(DiffColors.background(for: line.kind))
            } else {
                Color.secondary.opacity(0.06)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DiffGutter: View {
    let number: Int?
    let kind: DiffLine.Kind

    var body: some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .padding(.vertical, 1)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(DiffColors.gutterBackground(for: kind))
    }
}

private struct DiffLineContent: View {
    let line: DiffDisplayLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(marker)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(DiffColors.attributedText(line))
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .hunk, .context, .note: return ""
        }
    }
}
