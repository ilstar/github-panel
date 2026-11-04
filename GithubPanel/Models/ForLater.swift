import Foundation

/// My PRs split in two: the pull requests I am working on, then the ones parked under For Later,
/// such as a pull request waiting on another one or on someone else. Both keep GitHub's order, except that
/// stacked pull requests are kept together, at the place of the stack's latest update.
struct MyPullRequestSections: Equatable {
    static let forLaterTitle = "For Later"

    let activeEntries: [MyPullRequestEntry]
    let forLaterEntries: [MyPullRequestEntry]
    /// Stack positions keyed by row id, worked out across both sections so the numbers match the whole stack.
    let stackPositions: [String: PullRequestStackPosition]

    init(rows: [PullRequestRow], forLaterIDs: Set<String>) {
        let positions = PullRequestStacks.positions(in: rows)
        stackPositions = positions
        activeEntries = PullRequestStacks.entries(rows.filter { !forLaterIDs.contains($0.id) }, positions: positions)
        forLaterEntries = PullRequestStacks.entries(rows.filter { forLaterIDs.contains($0.id) }, positions: positions)
    }

    /// The rows in the order they are drawn.
    var active: [PullRequestRow] { activeEntries.flatMap(\.rows) }
    var forLater: [PullRequestRow] { forLaterEntries.flatMap(\.rows) }

    /// The row ids in the order they are drawn. A collapsed For Later section draws no rows.
    func visibleIDs(isForLaterExpanded: Bool) -> [String] {
        (active + (isForLaterExpanded ? forLater : [])).map(\.id)
    }
}

/// The pull request ids parked under For Later, as saved to defaults.
enum ForLaterStorage {
    static func decode(_ string: String?) -> Set<String> {
        guard let string,
              let ids = try? JSONDecoder().decode([String].self, from: Data(string.utf8)) else { return [] }
        return Set(ids)
    }

    static func encode(_ ids: Set<String>) -> String {
        let data = (try? JSONEncoder().encode(ids.sorted())) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
