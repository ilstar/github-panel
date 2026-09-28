import Foundation

/// A review event worth a macOS notification: someone reviewed my pull request, or asked for my review.
struct PullRequestNotification: Equatable {
    enum Kind: Equatable {
        case approved(by: [String])
        case changesRequested(by: [String])
        /// Nil when GitHub gives no author, such as for a deleted account.
        case reviewRequested(by: String?)
    }

    let kind: Kind
    let reference: PullRequestReference
    let pullRequestTitle: String
    let htmlURL: URL

    var heading: String {
        switch kind {
        case .approved: return "Approved"
        case .changesRequested: return "Changes Requested"
        case .reviewRequested: return "Review Requested"
        }
    }

    /// "octocat and hubot approved acme/widgets#7: Add tests"
    var body: String {
        let place = "\(reference.id): \(pullRequestTitle)"
        switch kind {
        case let .approved(logins):
            return "\(Self.names(logins)) approved \(place)"
        case let .changesRequested(logins):
            return "\(Self.names(logins)) requested changes on \(place)"
        case let .reviewRequested(author):
            return "\(author ?? "Someone") wants your review on \(place)"
        }
    }

    private static func names(_ logins: [String]) -> String {
        ListFormatter.localizedString(byJoining: logins)
    }
}
