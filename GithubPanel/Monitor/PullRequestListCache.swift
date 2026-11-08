import Foundation
import Combine

/// A list as last loaded from GitHub, saved to the local store so it shows straight away when the app starts again,
/// before the first refresh comes back.
struct CachedPullRequestList<Rows: Codable & Equatable>: Equatable {
    /// When GitHub returned the list.
    let savedAt: Date
    let rows: Rows
}

/// My PRs, To Review, and the History pages as last loaded, with whether each is loading and how its last load went.
/// The sync engine fills it and `PRMonitor` shows what it publishes. Lists are saved to the store, and when they last
/// loaded comes from `sync_state`, so both show right away after a restart.
@MainActor
final class PullRequestListCache {
    struct State: Equatable {
        /// When GitHub last returned the list.
        var fetchedAt: Date?
        var lastError: String?
        var isLoading = false
    }

    enum Change: Equatable {
        /// GitHub returned the list.
        case loaded(PullRequestListKind)
        /// Its rows changed some other way, or it started or stopped loading, or failed.
        case changed(PullRequestListKind)
    }

    let updates = PassthroughSubject<Change, Never>()

    private(set) var open: [PullRequestRow]?
    /// The token's login, from My PRs or the engine's lookup, so the viewer's unsent comments show as theirs. Not saved.
    var viewerLogin: String?
    /// Set when the last My PRs load left some out because the token isn't SSO-authorized. Not saved.
    private(set) var openSSOAuthorizationURL: URL?
    private(set) var reviewRequests: ReviewRequests?
    private var history: [Int: PullRequestHistoryPage] = [:]
    private var states: [PullRequestListKind: State] = [:]
    /// The loads running for each list. A list is loading while it has any.
    private var loads: [PullRequestListKind: Set<UUID>] = [:]
    private let store: LocalStore?

    init(store: LocalStore? = nil) {
        self.store = store
        restoreFromStore()
    }

    func state(of kind: PullRequestListKind) -> State {
        var state = states[kind] ?? State()
        state.isLoading = !(loads[kind] ?? []).isEmpty
        return state
    }

    func historyPage(_ page: Int) -> PullRequestHistoryPage? {
        if let cached = history[page] { return cached }
        guard let saved = store?.pullRequestList(.history(page: page), as: PullRequestHistoryPage.self) else {
            return nil
        }
        history[page] = saved.rows
        states[.history(page: page), default: State()].fetchedAt = savedFetchedAt(for: .history(page: page),
                                                                                  savedAt: saved.savedAt)
        return saved.rows
    }

    /// Whether the list has loaded, so a fresh `sync_state` still counts.
    func holds(_ kind: PullRequestListKind) -> Bool {
        switch kind {
        case .open: return open != nil
        case .reviewRequests: return reviewRequests != nil
        case .history(let page): return historyPage(page) != nil
        }
    }

    func store(_ result: OpenPullRequests, fetchedAt: Date) {
        viewerLogin = result.login
        open = result.rows
        openSSOAuthorizationURL = result.ssoAuthorizationURL
        save(result.rows, as: .open, fetchedAt: fetchedAt)
    }

    func store(_ requests: ReviewRequests, fetchedAt: Date) {
        reviewRequests = requests
        save(requests, as: .reviewRequests, fetchedAt: fetchedAt)
    }

    func store(_ page: PullRequestHistoryPage, asPage number: Int, fetchedAt: Date) {
        history[number] = page
        save(page, as: .history(page: number), fetchedAt: fetchedAt)
    }

    /// Takes a merged pull request off My PRs until the next load.
    func removeOpenPullRequest(id: String) {
        guard let rows = open, rows.contains(where: { $0.id == id }) else { return }
        open = rows.filter { $0.id != id }
        if let open, let fetchedAt = states[.open]?.fetchedAt {
            store?.savePullRequestList(CachedPullRequestList(savedAt: fetchedAt, rows: open), as: .open)
        }
        updates.send(.changed(.open))
    }

    /// Shows an error above the list until it loads again, such as a failed load or a failed merge from a row.
    func showError(_ message: String, on kind: PullRequestListKind) {
        states[kind, default: State()].lastError = message
        updates.send(.changed(kind))
    }

    func startLoading(_ kind: PullRequestListKind, id: UUID) {
        loads[kind, default: []].insert(id)
        states[kind, default: State()].lastError = nil
        updates.send(.changed(kind))
    }

    func stopLoading(_ kind: PullRequestListKind, id: UUID) {
        guard loads[kind]?.remove(id) != nil else { return }
        updates.send(.changed(kind))
    }

    /// Forgets the running loads, such as when the token changes. Their results are dropped.
    func stopAllLoading() {
        let kinds = loads.filter { !$0.value.isEmpty }.keys
        loads = [:]
        for kind in kinds { updates.send(.changed(kind)) }
    }

    /// Empties the lists and deletes the saved ones, such as when the token is removed.
    func removeAll() {
        viewerLogin = nil
        open = nil
        openSSOAuthorizationURL = nil
        reviewRequests = nil
        history = [:]
        states = [:]
        loads = [:]
        store?.removePullRequestLists()
    }

    private func save<Rows: Codable & Equatable>(_ rows: Rows, as kind: PullRequestListKind, fetchedAt: Date) {
        states[kind, default: State()].fetchedAt = fetchedAt
        states[kind]?.lastError = nil
        store?.savePullRequestList(CachedPullRequestList(savedAt: fetchedAt, rows: rows), as: kind)
        updates.send(.loaded(kind))
    }

    private func restoreFromStore() {
        guard let store else { return }
        if let cached = store.pullRequestList(.open, as: [PullRequestRow].self) {
            open = cached.rows
            states[.open] = State(fetchedAt: savedFetchedAt(for: .open, savedAt: cached.savedAt))
        }
        if let cached = store.pullRequestList(.reviewRequests, as: ReviewRequests.self) {
            reviewRequests = cached.rows
            states[.reviewRequests] = State(fetchedAt: savedFetchedAt(for: .reviewRequests, savedAt: cached.savedAt))
        }
    }

    /// When the saved list last loaded, from `sync_state`. A token change clears that, so it falls back to when
    /// the list was saved.
    private func savedFetchedAt(for kind: PullRequestListKind, savedAt: Date) -> Date {
        store?.syncStateNow(for: kind.key)?.fetchedAt ?? savedAt
    }
}
