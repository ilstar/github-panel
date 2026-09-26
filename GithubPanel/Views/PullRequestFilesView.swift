import SwiftUI
import AppKit

struct PullRequestFilesView: View {
    let files: [PullRequestFile]
    let diffLines: [String: [DiffLine]]
    let filesURL: URL

    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                toolbar

                if files.isEmpty {
                    Text("No files changed.")
                        .foregroundStyle(.secondary)
                }

                ForEach(files) { file in
                    fileSection(file)
                }
            }
            .padding(24)
        }
    }

    private var toolbar: some View {
        HStack {
            Text(files.count == 1 ? "1 file" : "\(files.count) files")
                .font(.callout.weight(.semibold))
            Spacer()
            Button("Expand All") { collapsed = [] }
                .disabled(collapsed.isEmpty)
            Button("Collapse All") { collapsed = Set(files.map(\.filename)) }
                .disabled(collapsed.count == files.count)
        }
    }

    private func fileSection(_ file: PullRequestFile) -> some View {
        let isCollapsed = collapsed.contains(file.filename)
        return VStack(alignment: .leading, spacing: 0) {
            PullRequestFileHeader(file: file, isCollapsed: isCollapsed) {
                if isCollapsed {
                    collapsed.remove(file.filename)
                } else {
                    collapsed.insert(file.filename)
                }
            }

            if !isCollapsed {
                Divider()
                if let lines = diffLines[file.filename], !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            DiffLineRow(line: line)
                        }
                    }
                } else {
                    HStack(spacing: 4) {
                        Text(file.patch == nil ? "Binary file or diff too large to show here." : "No changes to show.")
                        Link("View on GitHub", destination: filesURL)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
    }
}

struct PullRequestFileHeader: View {
    let file: PullRequestFile
    let isCollapsed: Bool
    let onToggle: () -> Void

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

            Spacer(minLength: 8)

            Text("+\(file.additions)")
                .foregroundStyle(DiffColors.additionText)
            Text("−\(file.deletions)")
                .foregroundStyle(DiffColors.deletionText)
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
}

struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)

            Text(marker)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .note ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 1)
        .background(background)
    }

    private func lineNumber(_ number: Int?) -> some View {
        Text(number.map(String.init) ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 48, alignment: .trailing)
            .padding(.trailing, 8)
            .background(gutterBackground)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .hunk, .context, .note: return ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return DiffColors.additionBackground
        case .deletion: return DiffColors.deletionBackground
        case .hunk: return DiffColors.hunkBackground
        case .context, .note: return .clear
        }
    }

    private var gutterBackground: Color {
        switch line.kind {
        case .addition: return DiffColors.additionBackground
        case .deletion: return DiffColors.deletionBackground
        case .hunk: return DiffColors.hunkBackground
        case .context, .note: return Color.secondary.opacity(0.04)
        }
    }
}
