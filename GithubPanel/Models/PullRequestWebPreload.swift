import Foundation

/// The two pages of a pull request the GitHub pane keeps loaded: the conversation and the diff.
enum PullRequestWebPage: Equatable, CaseIterable {
    case conversation
    case files

    func url(for reference: PullRequestReference) -> URL {
        switch self {
        case .conversation: return reference.webURL
        case .files: return reference.webURL.appendingPathComponent("files")
        }
    }

    /// The paths GitHub links to for this page of `reference`. The new diff view lives under "changes".
    func paths(for reference: PullRequestReference) -> [String] {
        let base = "/\(reference.repoFullName)/pull/\(reference.number)"
        switch self {
        case .conversation: return [base]
        case .files: return [base + "/files", base + "/changes"]
        }
    }

    /// Which page of `reference` a github.com URL shows, or nil for any other page. Query strings and anchors,
    /// such as a link to one comment, make it a different page.
    static func page(of url: URL?, for reference: PullRequestReference) -> PullRequestWebPage? {
        guard let url, WebNavigationPolicy.isGitHubHost(url.host),
              url.query == nil, url.fragment == nil else { return nil }
        var path = url.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return allCases.first { $0.paths(for: reference).contains(path) }
    }

    /// True when a web view at `url` whose last response had `statusCode` shows this page of `reference`, signed
    /// in. A redirect to GitHub's sign-in page lands on another URL, a private pull request gives a 404 at its own
    /// URL when signed out, and a public one gives a 200 with the signed-out page, so all three are checked.
    /// `isSignedIn` nil means unknown, such as a page without GitHub's sign-in meta tag.
    func isShown(at url: URL?, statusCode: Int?, isSignedIn: Bool?, for reference: PullRequestReference) -> Bool {
        guard Self.page(of: url, for: reference) == self, isSignedIn != false else { return false }
        guard let statusCode else { return true }
        return (200..<300).contains(statusCode)
    }
}

/// A pull request the GitHub pane keeps loaded, with the time GitHub last changed it, so a page loaded before a
/// change is loaded again.
struct PullRequestWebCandidate: Hashable {
    let reference: PullRequestReference
    let version: Date?
}

enum PullRequestWebPreload {
    /// How many pull requests keep their pages loaded. Each keeps two web views, and each web view has its own
    /// web content process, so this bounds the memory the pane takes.
    static let capacity = 12

    /// The pull requests to keep loaded, most wanted first: the selected one, then the visible list outward
    /// from it, rows below before rows above, then the other list in order.
    static func plan(selected: PullRequestReference?,
                     visible: [PullRequestWebCandidate],
                     other: [PullRequestWebCandidate],
                     capacity: Int = PullRequestWebPreload.capacity) -> [PullRequestWebCandidate] {
        let selectedIndex = visible.firstIndex { $0.reference == selected }
        let outward = visible.indices.sorted { lhs, rhs in
            guard let selectedIndex else { return lhs < rhs }
            let left = distance(lhs, from: selectedIndex), right = distance(rhs, from: selectedIndex)
            return left == right ? lhs > rhs : left < right
        }.map { visible[$0] }

        var ordered: [PullRequestWebCandidate] = []
        if let selected, selectedIndex == nil {
            let known = other.first { $0.reference == selected }
            ordered.append(known ?? PullRequestWebCandidate(reference: selected, version: nil))
        }
        var seen = Set<PullRequestReference>()
        return (ordered + outward + other)
            .filter { seen.insert($0.reference).inserted }
            .prefix(max(capacity, selected == nil ? 0 : 1))
            .map { $0 }
    }

    private static func distance(_ index: Int, from selected: Int) -> Int {
        abs(index - selected)
    }
}
