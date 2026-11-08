import Foundation

/// My PRs in groups by whose move it is (see ``MyPullRequestGroup``), then the ones parked under For Later,
/// such as a pull request waiting on another one or on someone else. Each group keeps GitHub's order, except that
/// stacked pull requests are kept together, at the place of the stack's latest update. A stack goes in the most
/// urgent group of any of its pull requests, so one failing pull request pulls its whole stack up to Needs You.
struct MyPullRequestSections: Equatable {
    static let forLaterTitle = "For Later"

    struct Group: Identifiable, Equatable {
        let group: MyPullRequestGroup
        let entries: [MyPullRequestEntry]

        var id: MyPullRequestGroup { group }
        var rows: [PullRequestRow] { entries.flatMap(\.rows) }
    }

    /// The groups with at least one pull request, most urgent first.
    let groups: [Group]
    let forLaterEntries: [MyPullRequestEntry]
    /// Stack positions keyed by row id, worked out across all sections so the numbers match the whole stack.
    let stackPositions: [String: PullRequestStackPosition]
    /// Each row's own group and reason, keyed by row id. For Later rows have one too.
    let statuses: [String: MyPullRequestStatus]

    init(rows: [PullRequestRow], forLaterIDs: Set<String>, botReviewer: String? = nil) {
        let positions = PullRequestStacks.positions(in: rows)
        stackPositions = positions
        let statuses = Dictionary(rows.map { ($0.id, MyPullRequestStatus($0, botReviewer: botReviewer)) },
                                  uniquingKeysWith: { first, _ in first })
        self.statuses = statuses

        let activeEntries = PullRequestStacks.entries(rows.filter { !forLaterIDs.contains($0.id) }, positions: positions)
        var byGroup: [MyPullRequestGroup: [MyPullRequestEntry]] = [:]
        for entry in activeEntries {
            let group = entry.rows.compactMap { statuses[$0.id]?.group }.min { $0.rank < $1.rank } ?? .inReview
            byGroup[group, default: []].append(entry)
        }
        groups = MyPullRequestGroup.allCases.compactMap { group in
            byGroup[group].map { Group(group: group, entries: $0) }
        }
        forLaterEntries = PullRequestStacks.entries(rows.filter { forLaterIDs.contains($0.id) }, positions: positions)
    }

    /// The entries above For Later, in the order they are drawn.
    var activeEntries: [MyPullRequestEntry] { groups.flatMap(\.entries) }

    /// The rows in the order they are drawn.
    var active: [PullRequestRow] { activeEntries.flatMap(\.rows) }
    var forLater: [PullRequestRow] { forLaterEntries.flatMap(\.rows) }

    /// How many pull requests are waiting on the author, for the badge on the My PRs tab.
    var needsYouCount: Int { groups.first { $0.group == .needsYou }?.rows.count ?? 0 }

    /// The group a row is drawn under, or nil when it is under For Later or not on the list.
    func group(containing id: String) -> MyPullRequestGroup? {
        groups.first { $0.rows.contains { $0.id == id } }?.group
    }

    /// The row ids in the order they are drawn. Collapsed groups and a collapsed For Later draw no rows.
    func visibleIDs(collapsed: Set<MyPullRequestGroup> = [], isForLaterExpanded: Bool) -> [String] {
        let shown = groups.filter { !collapsed.contains($0.group) }.flatMap(\.rows)
        return (shown + (isForLaterExpanded ? forLater : [])).map(\.id)
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
