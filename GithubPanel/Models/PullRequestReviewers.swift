import Foundation

/// One entry in a pull request's Reviewers list: a user or team asked to review, or a user who reviewed.
struct PullRequestReviewer: Identifiable, Equatable {
    enum Kind: Equatable {
        case user
        case team
    }

    enum State: Equatable {
        /// Asked to review and has not reviewed since.
        case pending
        case approved
        case changesRequested
        case commented
        case dismissed
    }

    /// A login, or `org/team-slug` for a team.
    let name: String
    let kind: Kind
    let state: State
    /// Requested because CODEOWNERS names them.
    var isCodeOwner = false
    /// Teams whose request this user's review fulfilled.
    var onBehalfOf: [String] = []
    /// For a re-requested reviewer, the verdict of their earlier review.
    var previousState: State?

    var id: String { Self.id(name: name, kind: kind) }

    static func id(name: String, kind: Kind) -> String {
        "\(kind == .team ? "team" : "user"):\(name.lowercased())"
    }

    /// GitHub's tooltip for the reviewer's status icon.
    var helpText: String {
        let teams = onBehalfOf.isEmpty ? "" : " on behalf of \(onBehalfOf.joined(separator: ", "))"
        switch state {
        case .pending:
            var text = "Awaiting requested review from \(name)"
            if let previousState, let verb = previousState.pastTense {
                text += ". \(name) previously \(verb)"
            }
            return text
        case .approved: return "\(name) approved these changes\(teams)"
        case .changesRequested: return "\(name) requested changes\(teams)"
        case .commented: return "\(name) left review comments\(teams)"
        case .dismissed: return "\(name)'s review was dismissed"
        }
    }
}

extension PullRequestReviewer.State {
    fileprivate var pastTense: String? {
        switch self {
        case .approved: return "approved these changes"
        case .changesRequested: return "requested changes"
        case .commented: return "left review comments"
        case .pending, .dismissed: return nil
        }
    }
}

/// A pull request's reviewers, built the way GitHub's Reviewers sidebar is.
struct PullRequestReviewers: Equatable {
    /// A submitted review: the latest one by its author.
    struct Review: Equatable {
        let author: String
        /// GitHub's review state: APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED or PENDING.
        let state: String
        var onBehalfOf: [String] = []
    }

    /// An open request for a review.
    struct Request: Equatable {
        let name: String
        let kind: PullRequestReviewer.Kind
        var asCodeOwner = false
    }

    var decision: ReviewDecision?
    var reviewers: [PullRequestReviewer] = []

    static let none = PullRequestReviewers()

    init(decision: ReviewDecision? = nil, reviewers: [PullRequestReviewer] = []) {
        self.decision = decision
        self.reviewers = reviewers
    }

    /// An open request wins over an earlier review: GitHub shows a re-requested reviewer as waiting.
    /// A team's request goes away once a member reviews on its behalf, so that team is not listed.
    /// The author's own replies count as reviews on GitHub, but the sidebar leaves them out.
    init(decision: ReviewDecision?, reviews: [Review], requests: [Request], authorLogin: String) {
        var latest: [String: Review] = [:]
        for review in reviews where review.state != "PENDING" && review.author.caseInsensitiveCompare(authorLogin) != .orderedSame {
            latest[review.author.lowercased()] = review
        }
        var reviewers: [PullRequestReviewer] = []
        var requestedUsers: Set<String> = []
        for request in requests {
            let key = request.name.lowercased()
            if request.kind == .user {
                guard requestedUsers.insert(key).inserted else { continue }
            }
            reviewers.append(PullRequestReviewer(name: request.name,
                                                 kind: request.kind,
                                                 state: .pending,
                                                 isCodeOwner: request.asCodeOwner,
                                                 previousState: request.kind == .user ? latest[key].flatMap { Self.state($0.state) } : nil))
        }
        for review in latest.values where !requestedUsers.contains(review.author.lowercased()) {
            guard let state = Self.state(review.state) else { continue }
            reviewers.append(PullRequestReviewer(name: review.author, kind: .user, state: state, onBehalfOf: review.onBehalfOf))
        }
        self.init(decision: decision,
                  reviewers: reviewers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    private static func state(_ githubState: String) -> PullRequestReviewer.State? {
        switch githubState {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "COMMENTED": return .commented
        case "DISMISSED": return .dismissed
        default: return nil
        }
    }

    /// Whether the user or team has an open review request.
    func isRequested(_ id: String) -> Bool {
        reviewers.contains { $0.id == id && $0.state == .pending }
    }

    /// The list once GitHub accepts a new review request, or a removed one, before it reloads.
    /// A removed request brings back the reviewer's earlier verdict, if they had one.
    func settingRequest(name: String, kind: PullRequestReviewer.Kind, requested: Bool) -> PullRequestReviewers {
        let id = PullRequestReviewer.id(name: name, kind: kind)
        let existing = reviewers.first { $0.id == id }
        var reviewers = reviewers.filter { $0.id != id }
        if requested {
            let previousState = existing?.state == .pending ? existing?.previousState : existing?.state
            reviewers.append(PullRequestReviewer(name: existing?.name ?? name, kind: kind, state: .pending,
                                                 isCodeOwner: existing?.isCodeOwner ?? false,
                                                 previousState: previousState))
        } else if let existing, existing.state != .pending {
            reviewers.append(existing)
        } else if let existing, let previousState = existing.previousState {
            reviewers.append(PullRequestReviewer(name: existing.name, kind: kind, state: previousState))
        }
        return PullRequestReviewers(decision: decision,
                                    reviewers: reviewers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }

    var approvals: Int { reviewers.filter { $0.state == .approved }.count }
    var changeRequests: Int { reviewers.filter { $0.state == .changesRequested }.count }
    var pendingCount: Int { reviewers.filter { $0.state == .pending }.count }

    /// The verdict at the top of the list, worded like GitHub's merge box.
    var summary: (title: String, detail: String?, tone: ReviewBadge?) {
        switch decision {
        case .changesRequested:
            return ("Changes requested", Self.count(changeRequests, "review", "requesting changes"), .changesRequested)
        case .approved:
            return ("Changes approved", Self.count(approvals, "approving review", nil), .approved)
        case .reviewRequired:
            let detail = Self.count(approvals, "approving review", nil).map { "\($0) so far. More are required by reviewers with write access." }
                ?? "At least 1 approving review is required by reviewers with write access."
            return ("Review required", detail, .needsReview)
        case nil:
            if changeRequests > 0 { return ("Changes requested", Self.count(changeRequests, "review", "requesting changes"), .changesRequested) }
            if approvals > 0 { return ("Approved", Self.count(approvals, "approving review", nil), .approved) }
            if pendingCount > 0 { return ("Awaiting review", Self.count(pendingCount, "review", "requested"), .awaitingReview) }
            return ("No reviews", nil, nil)
        }
    }

    private static func count(_ count: Int, _ noun: String, _ suffix: String?) -> String? {
        guard count > 0 else { return nil }
        let text = "\(count) \(noun)\(count == 1 ? "" : "s")"
        return suffix.map { "\(text) \($0)" } ?? text
    }
}

/// A user or team the reviewer picker offers.
struct ReviewerCandidate: Identifiable, Equatable {
    /// A login, or `org/team-slug` for a team.
    let name: String
    let kind: PullRequestReviewer.Kind
    /// The user's full name or the team's display name.
    var detail: String?
    /// GitHub suggests them, usually because they recently changed the same files.
    var isSuggested = false

    var id: String { PullRequestReviewer.id(name: name, kind: kind) }

    /// Suggestions first, then users and teams, each once, leaving out the author, who cannot review their own pull request.
    /// Suggestions only stay when they match the search, since GitHub returns them whatever was typed.
    static func merged(suggested: [ReviewerCandidate], users: [ReviewerCandidate], teams: [ReviewerCandidate],
                       query: String, authorLogin: String) -> [ReviewerCandidate] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matching = suggested.filter { candidate in
            query.isEmpty || candidate.name.localizedCaseInsensitiveContains(query)
                || candidate.detail?.localizedCaseInsensitiveContains(query) == true
        }
        var seen: Set<String> = [PullRequestReviewer.id(name: authorLogin, kind: .user)]
        return (matching + users + teams).filter { seen.insert($0.id).inserted }
    }
}
