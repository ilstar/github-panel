import Foundation

enum ListNavigation {
    /// The id `offset` steps from `current`, stopping at either end. Starts from the first id when nothing is
    /// selected yet or the selection is no longer in the list.
    static func neighbor<ID: Equatable>(of current: ID?, in ids: [ID], offset: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    /// The id to select once the list changes from `oldIDs` to `newIDs`: the current one while it is still listed,
    /// otherwise the next row that is, so reviewing or merging down the list does not jump back to its top.
    static func selection<ID: Equatable>(after current: ID?, oldIDs: [ID], newIDs: [ID]) -> ID? {
        guard let current, let index = oldIDs.firstIndex(of: current) else {
            return current.flatMap { newIDs.contains($0) ? $0 : nil } ?? newIDs.first
        }
        if newIDs.contains(current) { return current }
        return oldIDs[(index + 1)...].first { newIDs.contains($0) }
            ?? oldIDs[..<index].last { newIDs.contains($0) }
            ?? newIDs.first
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
