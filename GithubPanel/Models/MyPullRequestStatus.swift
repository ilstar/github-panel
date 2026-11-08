import Foundation

/// The group a pull request falls in on My PRs, by whose move it is. The cases run from most to least urgent,
/// which is also the order the groups are drawn in.
enum MyPullRequestGroup: String, CaseIterable, Identifiable, Codable {
    /// A conflict, failed checks, requested changes, or nobody asked to review: the author has to act.
    case needsYou
    /// Passing, reviewed as the base branch requires, and up to date: one click from merged.
    case readyToMerge
    /// Checks are still running.
    case building
    /// Reviewers have yet to answer.
    case inReview
    /// In the merge queue, or set to auto-merge: it lands without the author.
    case merging
    case drafts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .readyToMerge: return "Ready to Merge"
        case .building: return "Building"
        case .inReview: return "In Review"
        case .merging: return "Merging"
        case .drafts: return "Drafts"
        }
    }

    /// Where the group comes in the list: lower is more urgent.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Which group a pull request belongs to on My PRs, and the short reason shown on its row.
struct MyPullRequestStatus: Equatable {
    let group: MyPullRequestGroup
    let reason: String

    /// Each rule is tried in turn, so a pull request lands in the first group that fits. A conflict or failed
    /// checks come first, even on a draft, because they are the author's to fix. `botReviewer` is a login from
    /// ``BotReviewer/normalized(_:)``; its review counts like a person's.
    init(_ pr: PullRequestRow, botReviewer: String? = nil) {
        let reviews = pr.reviewStatus
        // The people's reviews and the bot's, read the same way as the row's review chips.
        let people = botReviewer.map(reviews.excludingBot) ?? reviews
        let bot = botReviewer.map(reviews.botIndicator(for:))
        let isWaiting = (people.indicator == .waiting && !people.waitingOn.isEmpty) || bot == .waiting

        if pr.mergeStateStatus == "DIRTY" {
            self.init(.needsYou, "Merge conflict")
        } else if pr.status == .failure || pr.status == .error {
            self.init(.needsYou, "Checks failed")
        } else if pr.isDraft {
            self.init(.drafts, "Draft")
        } else if people.indicator == .changesRequested || bot == .changesRequested {
            let names = reviews.changesRequestedBy
            self.init(.needsYou, names.isEmpty ? "Changes requested" : "Changes requested by \(Self.list(names))")
        } else if pr.isInMergeQueue {
            self.init(.merging, "In the merge queue")
        } else if pr.status == .pending {
            if pr.isAutoMergeEnabled {
                self.init(.merging, "Auto-merge when checks pass")
            } else {
                self.init(.building, "Checks running")
            }
        } else if isWaiting {
            self.init(.inReview, "Waiting on \(Self.list(reviews.waitingOn))")
        } else if people.decision == .reviewRequired {
            self.init(.needsYou, people.approvedBy.isEmpty ? "No reviewer requested" : "Needs another approval")
        } else if pr.isAutoMergeEnabled {
            self.init(.merging, "Auto-merge is on")
        } else if pr.canMergeImmediately {
            let names = reviews.approvedBy
            self.init(.readyToMerge, names.isEmpty ? "Ready to merge" : "Approved by \(Self.list(names))")
        } else if pr.mergeStateStatus == "BEHIND" {
            self.init(.needsYou, "Behind the base branch")
        } else if pr.mergeStateStatus == "BLOCKED" {
            self.init(.needsYou, "Blocked by branch rules")
        } else {
            // UNKNOWN while GitHub works out whether it can merge; it settles on the next refresh.
            self.init(.building, "Checking mergeability")
        }
    }

    init(_ group: MyPullRequestGroup, _ reason: String) {
        self.group = group
        self.reason = reason
    }

    /// "alex", "alex and maria", or "alex, maria and 2 more".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}

/// The My PRs groups the person has folded away, as saved to defaults.
enum CollapsedGroupsStorage {
    static let defaultsKey = "GithubPanel.collapsedMyPullRequestGroups"

    static func decode(_ string: String) -> Set<MyPullRequestGroup> {
        Set(string.split(separator: ",").compactMap { MyPullRequestGroup(rawValue: String($0)) })
    }

    static func encode(_ groups: Set<MyPullRequestGroup>) -> String {
        MyPullRequestGroup.allCases.filter(groups.contains).map(\.rawValue).joined(separator: ",")
    }
}
