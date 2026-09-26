import Foundation

/// One row of the changed-files tree: a directory or a file, indented by depth.
struct FileTreeRow: Equatable, Identifiable {
    enum Kind: Equatable {
        case directory
        case file
    }

    /// The full path. Directory ids have no trailing slash.
    let id: String
    let name: String
    let depth: Int
    let kind: Kind
}

enum FileTree {
    /// Builds tree rows for the paths. Directories come before files, each sorted by name, and a directory
    /// whose only child is another directory is shown as one row, like `Sources/App`.
    static func rows(for paths: [String]) -> [FileTreeRow] {
        let root = Node()
        for path in paths {
            var node = root
            let parts = path.split(separator: "/").map(String.init)
            for part in parts.dropLast() {
                node = node.directory(named: part)
            }
            if let name = parts.last {
                node.files.append((name, path))
            }
        }

        var rows: [FileTreeRow] = []
        append(root, prefix: "", depth: 0, to: &rows)
        return rows
    }

    /// Whether the path matches a file-name search. Matching ignores case and treats the query as a substring.
    static func matches(_ path: String, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || path.localizedCaseInsensitiveContains(trimmed)
    }

    /// Leaves out the rows inside collapsed directories.
    static func visibleRows(_ rows: [FileTreeRow], collapsed: Set<String>) -> [FileTreeRow] {
        guard !collapsed.isEmpty else { return rows }
        return rows.filter { row in
            !collapsed.contains { row.id.hasPrefix($0 + "/") }
        }
    }

    private final class Node {
        var directories: [String: Node] = [:]
        var files: [(name: String, path: String)] = []

        func directory(named name: String) -> Node {
            if let existing = directories[name] { return existing }
            let node = Node()
            directories[name] = node
            return node
        }
    }

    private static func append(_ node: Node, prefix: String, depth: Int, to rows: inout [FileTreeRow]) {
        for name in node.directories.keys.sorted(by: sortsBefore) {
            var directory = node.directories[name]!
            var displayName = name
            var path = prefix + name
            while directory.files.isEmpty, directory.directories.count == 1, let (childName, child) = directory.directories.first {
                displayName += "/" + childName
                path += "/" + childName
                directory = child
            }
            rows.append(FileTreeRow(id: path, name: displayName, depth: depth, kind: .directory))
            append(directory, prefix: path + "/", depth: depth + 1, to: &rows)
        }
        for file in node.files.sorted(by: { sortsBefore($0.name, $1.name) }) {
            rows.append(FileTreeRow(id: file.path, name: file.name, depth: depth, kind: .file))
        }
    }

    private static func sortsBefore(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
