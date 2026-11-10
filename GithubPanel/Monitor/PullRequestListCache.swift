import Foundation
import Combine

/// My PRs, To Review, and the History pages as last loaded, with whether each is loading and how its last load went.
/// The sync engine fills it and `PRMonitor` shows what it publishes.
///
/// Each pull request has one record, which every list that holds it reads, along with the newest status any load saw
/// for it: a detail or checks load newer than the list updates its row too. Records and lists are saved to the store,
/// one row per pull request, and when lists last loaded comes from `sync_state`, so both show right away after a
/// restart.
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

    /// The token's login, from My PRs or the engine's lookup, so the viewer's unsent comments show as theirs. Not saved.
    var viewerLogin: String?
    /// Set when the last My PRs load left some out because the token isn't SSO-authorized. Not saved.
    private(set) var openSSOAuthorizationURL: URL?
    /// The pull requests the lists hold.
    private(set) var records: [PullRequestReference: PullRequestRecord] = [:]
    /// Each loaded list, in order.
    private var members: [PullRequestListKind: [PullRequestListMember]] = [:]
    private var infos: [PullRequestListKind: PullRequestListInfo] = [:]
    private var states: [PullRequestListKind: State] = [:]
    /// The loads running for each list. A list is loading while it has any.
    private var loads: [PullRequestListKind: Set<UUID>] = [:]
    private let store: LocalStore?

    init(store: LocalStore? = nil) {
        self.store = store
        restoreFromStore()
    }

    var open: [PullRequestRow]? {
        members[.open]?.compactMap { records[$0.reference]?.shownOpenRow }
    }

    var reviewRequests: ReviewRequests? {
        guard let members = members[.reviewRequests] else { return nil }
        func rows(in group: ReviewRequestGroup) -> [ReviewRequestRow] {
            members.filter { $0.reviewGroup == group }.compactMap { records[$0.reference]?.shownReviewRequestRow }
        }
        return ReviewRequests(fromMe: rows(in: .fromMe), fromMyTeams: rows(in: .fromMyTeams),
                              ssoAuthorizationURL: infos[.reviewRequests]?.ssoAuthorizationURL)
    }

    func state(of kind: PullRequestListKind) -> State {
        var state = states[kind] ?? State()
        state.isLoading = !(loads[kind] ?? []).isEmpty
        return state
    }

    func historyPage(_ page: Int) -> PullRequestHistoryPage? {
        guard let members = members[.history(page: page)], let info = infos[.history(page: page)],
              let perPage = info.perPage, let totalCount = info.totalCount else { return nil }
        return PullRequestHistoryPage(rows: members.compactMap { records[$0.reference]?.historyRow },
                                      page: info.page ?? page, perPage: perPage, totalCount: totalCount)
    }

    /// Whether the list has loaded, so a fresh `sync_state` still counts.
    func holds(_ kind: PullRequestListKind) -> Bool {
        members[kind] != nil
    }

    /// Saves My PRs. `observedAt` is when the request was sent, which orders it against other loads' statuses.
    func store(_ result: OpenPullRequests, fetchedAt: Date, observedAt: Date? = nil) {
        viewerLogin = result.login
        openSSOAuthorizationURL = result.ssoAuthorizationURL
        let observedAt = observedAt ?? fetchedAt
        save(.open, members: result.rows.map { PullRequestListMember(reference: $0.reference) },
             info: PullRequestListInfo(ssoAuthorizationURL: result.ssoAuthorizationURL), fetchedAt: fetchedAt) { records in
            for row in result.rows {
                records[row.reference, default: PullRequestRecord()].openRow = row
                records[row.reference]?.observe(row.status(observedAt: observedAt))
            }
        }
    }

    func store(_ requests: ReviewRequests, fetchedAt: Date, observedAt: Date? = nil) {
        let observedAt = observedAt ?? fetchedAt
        let members = ReviewRequestGroup.allCases.flatMap { group in
            requests.rows(in: group).map { PullRequestListMember(reference: $0.reference, reviewGroup: group) }
        }
        save(.reviewRequests, members: members,
             info: PullRequestListInfo(ssoAuthorizationURL: requests.ssoAuthorizationURL), fetchedAt: fetchedAt) { records in
            for row in requests.rows {
                records[row.reference, default: PullRequestRecord()].reviewRequestRow = row
                if let status = row.status(observedAt: observedAt) { records[row.reference]?.observe(status) }
            }
        }
    }

    func store(_ page: PullRequestHistoryPage, asPage number: Int, fetchedAt: Date) {
        save(.history(page: number), members: page.rows.map { PullRequestListMember(reference: $0.reference) },
             info: PullRequestListInfo(page: page.page, perPage: page.perPage, totalCount: page.totalCount),
             fetchedAt: fetchedAt) { records in
            for row in page.rows {
                records[row.reference, default: PullRequestRecord()].historyRow = row
            }
        }
    }

    /// Notes the head commit and checks a detail or checks load saw, which every list holding the pull request shows
    /// if it's newer than what they last loaded.
    func observe(_ status: PullRequestStatus, for reference: PullRequestReference) {
        var record = records[reference] ?? PullRequestRecord()
        let before = record.status
        record.observe(status)
        records[reference] = record
        guard record.status != before else { return }
        if let status = record.status { store?.savePullRequestStatus(status, for: reference) }
        for (kind, members) in members where members.contains(where: { $0.reference == reference }) {
            updates.send(.changed(kind))
        }
    }

    /// Takes a merged pull request off My PRs until the next load.
    func removeOpenPullRequest(id: String) {
        guard let rows = members[.open], rows.contains(where: { records[$0.reference]?.openRow?.id == id }) else { return }
        members[.open] = rows.filter { records[$0.reference]?.openRow?.id != id }
        if let fetchedAt = states[.open]?.fetchedAt { saveToStore(.open, savedAt: fetchedAt) }
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
        openSSOAuthorizationURL = nil
        records = [:]
        members = [:]
        infos = [:]
        states = [:]
        loads = [:]
        store?.removePullRequestLists()
    }

    /// Replaces a list, updating its pull requests' records with `update`, and drops records no list holds anymore.
    private func save(_ kind: PullRequestListKind, members: [PullRequestListMember], info: PullRequestListInfo,
                      fetchedAt: Date, update: (inout [PullRequestReference: PullRequestRecord]) -> Void) {
        update(&records)
        self.members[kind] = members
        infos[kind] = info
        let held = Set(self.members.values.joined().map(\.reference))
        records = records.filter { held.contains($0.key) }
        states[kind, default: State()].fetchedAt = fetchedAt
        states[kind]?.lastError = nil
        saveToStore(kind, savedAt: fetchedAt)
        updates.send(.loaded(kind))
        // Another list showing the same pull requests shows their new status too.
        let references = Set(members.map(\.reference))
        for (other, otherMembers) in self.members where other != kind
            && otherMembers.contains(where: { references.contains($0.reference) }) {
            updates.send(.changed(other))
        }
    }

    private func saveToStore(_ kind: PullRequestListKind, savedAt: Date) {
        guard let store, let members = members[kind], let info = infos[kind] else { return }
        let held = Dictionary(members.compactMap { member in records[member.reference].map { (member.reference, $0) } },
                              uniquingKeysWith: { first, _ in first })
        store.savePullRequestList(LocalStore.SavedPullRequestList(savedAt: savedAt, info: info, members: members),
                                  as: kind, records: held)
    }

    private func restoreFromStore() {
        guard let store else { return }
        let saved = store.pullRequestLists()
        records = saved.records
        for (kind, list) in saved.lists {
            members[kind] = list.members
            infos[kind] = list.info
            states[kind] = State(fetchedAt: savedFetchedAt(for: kind, savedAt: list.savedAt))
        }
    }

    /// When the saved list last loaded, from `sync_state`. A token change clears that, so it falls back to when
    /// the list was saved.
    private func savedFetchedAt(for kind: PullRequestListKind, savedAt: Date) -> Date {
        store?.syncStateNow(for: kind.key)?.fetchedAt ?? savedAt
    }
}
