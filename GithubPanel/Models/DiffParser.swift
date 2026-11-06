import Foundation

struct DiffLine: Equatable {
    enum Kind: Equatable {
        /// A `@@ -a,b +c,d @@` hunk header.
        case hunk
        case context
        case addition
        case deletion
        /// A `\ No newline at end of file` marker.
        case note
    }

    let kind: Kind
    /// The line's text without its leading `+`, `-`, or space.
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

/// A pull request's file diffs, each parsed the first time it is asked for. A big pull request has many
/// files, and parsing them all up front would hold up opening it.
struct LazyDiffLines {
    private var patches: [String: String] = [:]
    private var parsed: [String: [DiffLine]] = [:]

    init() {}

    init(_ files: [PullRequestFile]) {
        patches = Dictionary(files.map { ($0.filename, $0.patch ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    /// Nil when no file has this name.
    mutating func lines(for filename: String) -> [DiffLine]? {
        if let lines = parsed[filename] { return lines }
        guard let patch = patches[filename] else { return nil }
        let lines = DiffParser.parse(patch)
        parsed[filename] = lines
        return lines
    }
}

/// Parses the `patch` field GitHub returns for each changed file.
enum DiffParser {
    static func parse(_ patch: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        // A trailing newline ends the last line; it does not start a new one.
        let body = patch.hasSuffix("\n") ? String(patch.dropLast()) : patch
        guard !body.isEmpty else { return [] }

        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("@@") {
                if let start = hunkStart(line) {
                    oldLine = start.old
                    newLine = start.new
                }
                lines.append(DiffLine(kind: .hunk, text: line, oldLineNumber: nil, newLineNumber: nil))
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .addition, text: String(line.dropFirst()), oldLineNumber: nil, newLineNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .deletion, text: String(line.dropFirst()), oldLineNumber: oldLine, newLineNumber: nil))
                oldLine += 1
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(kind: .note, text: line, oldLineNumber: nil, newLineNumber: nil))
            } else {
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldLineNumber: oldLine, newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return lines
    }

    /// Reads the old and new starting line numbers from `@@ -12,5 +14,7 @@ ...`.
    static func hunkStart(_ header: String) -> (old: Int, new: Int)? {
        let parts = header.split(separator: " ")
        guard parts.count >= 3,
              parts[1].hasPrefix("-"),
              parts[2].hasPrefix("+"),
              let old = Int(parts[1].dropFirst().split(separator: ",")[0]),
              let new = Int(parts[2].dropFirst().split(separator: ",")[0]) else {
            return nil
        }
        return (old, new)
    }

    /// Splits a whole pull request's raw diff into each file's hunks, keyed by its new path
    /// (its old path when deleted), in the same form as GitHub's `patch` field.
    /// Files with no hunks, such as binary files or pure renames, are left out.
    static func patchesByFile(rawDiff: String) -> [String: String] {
        var patches: [String: String] = [:]
        var oldPath: String?
        var newPath: String?
        var hunks: [Substring] = []
        func finishFile() {
            if let path = newPath ?? oldPath, !hunks.isEmpty {
                patches[path] = hunks.joined(separator: "\n")
            }
            oldPath = nil
            newPath = nil
            hunks = []
        }
        for line in rawDiff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                finishFile()
            } else if !hunks.isEmpty || line.hasPrefix("@@") {
                hunks.append(line)
            } else if line.hasPrefix("--- a/") {
                oldPath = String(line.dropFirst("--- a/".count))
            } else if line.hasPrefix("+++ b/") {
                newPath = String(line.dropFirst("+++ b/".count))
            }
        }
        // The diff's final newline ends its last line; it is not an empty line of the last hunk.
        if hunks.last?.isEmpty == true { hunks.removeLast() }
        finishFile()
        return patches
    }
}
