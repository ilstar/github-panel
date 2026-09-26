import Foundation

enum ListNavigation {
    /// The id `offset` steps from `current`, stopping at either end. Starts from the first id when nothing is
    /// selected yet or the selection is no longer in the list.
    static func neighbor<ID: Equatable>(of current: ID?, in ids: [ID], offset: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }
}

extension PullRequestDetailTab {
    /// The tab to the right, wrapping around like Safari's tabs.
    var next: PullRequestDetailTab {
        Self.tab(after: self, offset: 1)
    }

    var previous: PullRequestDetailTab {
        Self.tab(after: self, offset: -1)
    }

    private static func tab(after tab: PullRequestDetailTab, offset: Int) -> PullRequestDetailTab {
        let tabs = allCases
        let index = tabs.firstIndex(of: tab)!
        return tabs[(index + offset + tabs.count) % tabs.count]
    }
}
