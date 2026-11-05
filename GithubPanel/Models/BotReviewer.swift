import Foundation

/// The review bot set in Settings, whose verdict gets its own chip on My PRs rows, between checks and reviews.
enum BotReviewer {
    static let defaultsKey = "GithubPanel.botReviewerLogin"

    /// The login as GraphQL reports it: no "@", no "[bot]" suffix (the REST API's spelling for GitHub Apps),
    /// lowercased since logins are case-insensitive. Nil when nothing is set.
    static func normalized(_ login: String) -> String? {
        var value = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("@") { value.removeFirst() }
        if value.hasSuffix("[bot]") { value.removeLast("[bot]".count) }
        return value.isEmpty ? nil : value
    }

    static func matches(_ login: String, bot: String) -> Bool {
        normalized(login) == bot
    }
}

extension PullRequestReviewStatus {
    /// Where the bot's review stands. A pending request comes first: GitHub drops a request once the reviewer
    /// answers, so one that is still there was made after the bot's last review, such as a re-review.
    /// `bot` is a login from ``BotReviewer/normalized(_:)``.
    func botIndicator(for bot: String) -> ReviewIndicator {
        func includesBot(_ logins: [String]) -> Bool { logins.contains { BotReviewer.matches($0, bot: bot) } }
        if includesBot(waitingOn) { return .waiting }
        if includesBot(changesRequestedBy) { return .changesRequested }
        if includesBot(approvedBy) { return .approved }
        return .none
    }

    /// The people's reviews, without the bot's. When the bot's review was all GitHub's verdict rested on,
    /// the verdict falls back to needing a review, since the base branch requires one.
    func excludingBot(_ bot: String) -> PullRequestReviewStatus {
        func withoutBot(_ logins: [String]) -> [String] { logins.filter { !BotReviewer.matches($0, bot: bot) } }
        var status = PullRequestReviewStatus(decision: decision,
                                             approvedBy: withoutBot(approvedBy),
                                             changesRequestedBy: withoutBot(changesRequestedBy),
                                             waitingOn: withoutBot(waitingOn))
        switch decision {
        case .approved where status.approvedBy.isEmpty && !approvedBy.isEmpty,
             .changesRequested where status.changesRequestedBy.isEmpty && !changesRequestedBy.isEmpty:
            status.decision = .reviewRequired
        default:
            break
        }
        return status
    }
}
