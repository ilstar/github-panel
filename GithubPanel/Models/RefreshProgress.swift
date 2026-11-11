import Foundation

/// How far a refresh has got through preloading the pull requests of My PRs and To Review, for the refresh button.
/// Each pull request counts in the first list it was queued from, so one in both lists counts once.
struct RefreshProgress: Equatable {
    enum List: Equatable {
        case myPullRequests
        case reviewRequests

        var title: String {
            switch self {
            case .myPullRequests: return PullRequestTab.open.title
            case .reviewRequests: return PullRequestTab.reviews.title
            }
        }
    }

    struct Count: Equatable {
        let completed: Int
        let total: Int
    }

    private var lists: [PullRequestReference: List] = [:]
    private var completed: Set<PullRequestReference> = []

    /// Counts a queued pull request. One queued again after it loaded, such as by a refresh during preloading, loads
    /// again, so it counts as not done.
    mutating func add(_ reference: PullRequestReference, to list: List) {
        if lists[reference] == nil { lists[reference] = list }
        completed.remove(reference)
    }

    mutating func complete(_ reference: PullRequestReference) {
        guard lists[reference] != nil else { return }
        completed.insert(reference)
    }

    func count(of list: List) -> Count {
        let references = lists.filter { $0.value == list }.keys
        return Count(completed: references.filter(completed.contains).count, total: references.count)
    }

    /// The text for the refresh button, such as "Refreshing My PRs 2/10…", counting the pull request loading now.
    /// Shows the list of `selectedTab` until it is done, then the other one. Nil once both are done.
    func text(selectedTab: PullRequestTab) -> String? {
        let order: [List] = selectedTab == .reviews ? [.reviewRequests, .myPullRequests]
                                                    : [.myPullRequests, .reviewRequests]
        for list in order {
            let count = count(of: list)
            guard count.completed < count.total else { continue }
            return "Refreshing \(list.title) \(count.completed + 1)/\(count.total)…"
        }
        return nil
    }
}
