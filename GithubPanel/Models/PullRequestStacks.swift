import Foundation

/// Where a pull request sits in a stack: pull requests in one repository where each one's base branch is the
/// branch of the one before it. The first one is based on a branch no other open pull request has, such as main.
struct PullRequestStackPosition: Equatable {
    /// The id of the stack's first pull request.
    let stackID: String
    /// 1 for the pull request at the bottom of the stack, the one to merge first.
    let number: Int
    let count: Int
    /// The pull request this one is based on, or nil for the bottom of the stack.
    let basePullRequestNumber: Int?

    var label: String { "\(number)/\(count)" }

    var helpText: String {
        let place = "Pull request \(number) of \(count) in a stack."
        guard let basePullRequestNumber else { return place + "\nThe bottom of the stack." }
        return place + "\nBased on #\(basePullRequestNumber)."
    }
}

/// A My PRs list item: one pull request, or the pull requests of one stack kept together.
enum MyPullRequestEntry: Identifiable, Equatable {
    case single(PullRequestRow)
    case stack([PullRequestRow])

    var id: String {
        switch self {
        case .single(let row): return row.id
        case .stack(let rows): return "stack:" + (rows.first?.id ?? "")
        }
    }

    var rows: [PullRequestRow] {
        switch self {
        case .single(let row): return [row]
        case .stack(let rows): return rows
        }
    }
}

enum PullRequestStacks {
    /// The stack positions of the pull requests in a stack of two or more, keyed by row id.
    static func positions(in rows: [PullRequestRow]) -> [String: PullRequestStackPosition] {
        var positions: [String: PullRequestStackPosition] = [:]
        for stack in stacks(in: rows) {
            let numbers = Dictionary(uniqueKeysWithValues: stack.map { ($0.row.id, $0.row.number) })
            for (offset, member) in stack.enumerated() {
                positions[member.row.id] = PullRequestStackPosition(stackID: stack[0].row.id,
                                                                    number: offset + 1,
                                                                    count: stack.count,
                                                                    basePullRequestNumber: member.parentID.flatMap { numbers[$0] })
            }
        }
        return positions
    }

    /// Rows in their list order, with each stack's rows pulled together, bottom of the stack first. A stack takes
    /// the place of its most recently updated pull request; everything else keeps its place.
    static func entries(_ rows: [PullRequestRow], positions: [String: PullRequestStackPosition]) -> [MyPullRequestEntry] {
        var members: [String: [PullRequestRow]] = [:]
        var anchors: [String: PullRequestRow] = [:]
        for row in rows {
            guard let stackID = positions[row.id]?.stackID else { continue }
            members[stackID, default: []].append(row)
            if let anchor = anchors[stackID], anchor.updatedAt >= row.updatedAt { continue }
            anchors[stackID] = row
        }
        return rows.compactMap { row in
            guard let stackID = positions[row.id]?.stackID, let stack = members[stackID] else { return .single(row) }
            guard anchors[stackID]?.id == row.id else { return nil }
            guard stack.count > 1 else { return .single(row) }
            return .stack(stack.sorted { (positions[$0.id]?.number ?? 0) < (positions[$1.id]?.number ?? 0) })
        }
    }

    private struct Member {
        let row: PullRequestRow
        let parentID: String?
    }

    /// Each stack of two or more, bottom first. A pull request based on a branch with two pull requests on top
    /// lists one branch of the tree after the other.
    private static func stacks(in rows: [PullRequestRow]) -> [[Member]] {
        func key(_ repo: String, _ branch: String) -> String { repo + "\u{0}" + branch }

        var byHead: [String: PullRequestRow] = [:]
        for row in rows {
            guard let head = row.headRefName else { continue }
            // Two open pull requests from one branch: the first, most recently updated, wins.
            let headKey = key(row.repoFullName, head)
            if byHead[headKey] == nil { byHead[headKey] = row }
        }
        func parent(of row: PullRequestRow) -> PullRequestRow? {
            guard let base = row.baseRefName,
                  let parent = byHead[key(row.repoFullName, base)],
                  parent.id != row.id else { return nil }
            return parent
        }

        var children: [String: [PullRequestRow]] = [:]
        for row in rows {
            if let parent = parent(of: row) {
                children[parent.id, default: []].append(row)
            }
        }

        var assigned: Set<String> = []
        var stacks: [[Member]] = []
        for row in rows where !assigned.contains(row.id) {
            guard parent(of: row) != nil || children[row.id] != nil else { continue }
            // Walk down to the bottom of the stack. Branches based on each other in a loop stop where they repeat.
            var bottom = row
            var seen: Set<String> = [row.id]
            while let next = parent(of: bottom), seen.insert(next.id).inserted {
                bottom = next
            }

            var stack: [Member] = []
            func visit(_ row: PullRequestRow, parentID: String?) {
                guard assigned.insert(row.id).inserted else { return }
                stack.append(Member(row: row, parentID: parentID))
                for child in children[row.id] ?? [] {
                    visit(child, parentID: row.id)
                }
            }
            visit(bottom, parentID: nil)
            if stack.count > 1 {
                stacks.append(stack)
            }
        }
        return stacks
    }
}
