# Local-First Sync — Plan

Goal: make the app feel instant everywhere. The UI never waits on GitHub. It
reads from a local database and renders right away. A background sync engine
is the only thing that talks to GitHub: it runs queued reads and writes and
saves what comes back into the database, and the UI updates from there.

```
 Views ──observe──▶ LocalStore (SQLite) ◀──writes── SyncEngine ──▶ GitHub
   │                                                  ▲
   └──── request(refresh / change, priority) ─────────┘
```

## Where we start

The app is already partway there:

- `PullRequestDetailCache` keeps up to 100 PRs (detail, files, comments,
  checks), saves them to one JSON file in Caches, and publishes `updates`.
  `PullRequestDetailViewModel` shows the cached entry first, then reloads.
- `CachedPullRequestList` saves the last My PRs / History / To Review lists to
  defaults, so they show right after a restart.
- `PRMonitor` refreshes on a timer, prefetches details for listed PRs, and backs
  off after throttled or auth failures.
- `PullRequestDetailViewModel.setTask` is optimistic: it updates the body right
  away, chains saves so the last click wins, and rolls back on failure.

What's missing: the fetch, cache, and render logic is mixed together in
`PRMonitor` (~950 lines) and `PullRequestDetailViewModel` (~700 lines). Requests
aren't deduped or ordered by priority across callers, and each write handles
its own optimistic state, or doesn't.

## Design

### LocalStore

- SQLite through [GRDB](https://github.com/groue/GRDB.swift), added as a Swift
  package next to KeyboardShortcuts and Sparkle. GRDB's `ValueObservation`
  is how views observe "the UI reads from the DB", and GRDB writes run off the
  main thread.
- One database file in Application Support (`<bundle id>/Store.sqlite`), since
  later steps keep pending changes in it that must survive a restart. Mock mode
  and tests use an in-memory database.
- Schema changes go through GRDB's `DatabaseMigrator`. If a migration fails,
  delete the file and start over, because everything except pending changes can
  be fetched again.
- Tables start as JSON blobs keyed by the PR, so models stay `Codable` and step
  1 can't change behavior. Split a blob into columns only when a query needs it.

| Table | Key | Holds |
|---|---|---|
| `pull_request_list` | list kind (`open`, `history:<page>`, `reviewRequests`) | rows blob, `savedAt` |
| `pull_request_detail` | `repoFullName`, `number` | content, comments, comment limits, checks, files since last review (blobs), `lastUsedAt` |
| `sync_state` | resource key | `fetchedAt`, `lastError`, `lastAttemptAt` |
| `pending_change` | id | PR key, kind, payload blob, `createdAt`, state (`pending` / `sending` / `failed`), error |

The detail table keeps the current limit: the 100 most recently used PRs.

### SyncEngine

- An actor that owns the `GitHubAPIClient` and the token. It's the only code that
  calls GitHub, except for live searches (reviewer and @mention autocomplete),
  which stay direct calls.
- Callers ask for a resource: `request(.detail(ref), priority: .userVisible)`,
  `.comments(ref, limits)`, `.checks(ref)`, `.changedFiles(...)`, `.openList`,
  `.history(page)`, `.reviewRequests`.
- **Dedupe**: a second request for a resource that's already in flight joins the
  running one, and a higher priority raises it. A request with `maxAge` zero (a
  refresh after a write, a reload) joins only a load that hasn't sent its request
  yet. Otherwise it waits for the running one and loads again, so it never gets
  data read before the write and the newer result is saved last.
- **Priority**: `.userVisible` (the PR or list the user is looking at) runs before
  `.background` (timer refresh, prefetch). Background requests run a few at a
  time, so they never hold up a user request.
- **Freshness**: `sync_state.fetchedAt` per resource. A request newer than a
  caller-given `maxAge` is skipped. Views can show how stale data is.
- **Backoff**: the throttled/auth backoff moves here from `PRMonitor` and applies
  to every request, lists and details alike. After a throttled or rejected
  request, every request fails with that error without being sent, for two
  refresh intervals, doubling after each failure up to 30 minutes, less half an
  interval so the timer tick due when it ends isn't skipped. Requests that were
  already sent and fail with it count as the same failure. A success sent after
  the backoff began, or a new token, ends it.
- **Credentials**: the engine reads the token and a session ID from `PRMonitor`.
  A result is saved only if the session still matches, checked on the main actor
  in the same step as the save, so nothing loaded with an old token lands after
  `removeAll`. A token change also cancels in-flight loads and clears `sync_state`.
- **Freshness counts only what the cache holds**: `fetchedAt` within `maxAge`
  skips a request only while the cache still has that resource, since it can be
  evicted or emptied after the row was written.
- Results go into `LocalStore` in one transaction per response. The engine never
  touches views or view models.

### Pending changes (optimistic writes)

What the UI shows = **the last server snapshot + pending changes applied on
top**. Pending changes live in `pending_change`. A pure function per change
kind (`apply(_ change, to: entry)`) builds what the view renders, so a background
refresh landing mid-write can't make the UI flicker back.

- The engine sends a PR's changes one at a time, in order. Different PRs send
  at the same time.
- On success, it refetches the affected resource, then writes the new snapshot
  and deletes the change **in the same transaction**. If the refetch fails, the
  change is applied to the cached snapshot instead, so it keeps showing.
- On failure, the change becomes `failed` with its error. The view shows it
  inline with Retry / Discard, and it stays applied until the user picks one.
  Composers keep their draft until the change is confirmed.
- A new change to the same field (title, body, one file's viewed mark, one
  thread, one reviewer) replaces an earlier one that hasn't started sending or
  that failed. One that's sending stays, and the new one sends after it.
- During a backoff, changes wait as `pending`. A failed write doesn't start the
  backoff, since GitHub also answers a write it doesn't allow with 403.
- A token change drops every pending and failed change, in memory and on disk.
  They were made as the old account, so sending them with the new token could
  act as the wrong person.
- After a restart:
  - **Safe to replay** (idempotent: setting a value, not adding one): task
    checkbox, title/body edit, file viewed, resolve thread, reviewer
    add/remove. These are sent again.
  - **Not replayed** (posting twice would be wrong): comments, replies, inline
    comments, reviews. These become `failed` ("Not sent — the app quit before
    GitHub answered") so the user decides.
- **Merge, enqueue, auto-merge, update branch and rerun checks stay direct calls
  that the user waits on.** Their failures (conflicts, required checks, a stale
  head SHA) need an answer right away, and replaying one later is dangerous.
  Only their follow-up refresh goes through the engine.

### What stays the same

- `GitHubAPIClient`, `GitHubAPI`, and `MockGitHubAPI` keep their shape. The engine
  wraps them.
- Notifications and check hooks stay in `PRMonitor`. It reacts to list changes
  in the store instead of to refresh results.
- Mock mode (`mise run mock`) keeps working throughout, with an in-memory store.

## Steps

Each step is its own branch and PR, starts from `main` after the previous one
merges, and leaves the app working. Every step adds tests and passes
`mise run test`.

Status: `[ ]` todo · `[~]` in progress · `[x]` done

1. [x] **LocalStore behind today's caches.** Add GRDB and `LocalStore` with
       migrations and the `pull_request_detail`, `pull_request_list`, and
       `sync_state` tables. Back `PullRequestDetailCache` and the saved PR lists
       with it, keeping their public interfaces (`entry`, `store`,
       `needsRefresh`, `removeAll`, `updates`, `waitForRestore`, `saveNow`). Drop
       the old `PullRequestDetails.json` and the list keys in defaults. Don't
       import their contents; they're only caches. Callers don't change.
2. [x] **SyncEngine for PR details.** Add `SyncEngine` with dedupe, priority,
       `sync_state` freshness, and backoff. Move detail, comments, checks, and
       changed-files fetches into it. `PullRequestDetailViewModel` observes the
       store and calls `engine.request(...)` instead of its fetch closures.
       `PRMonitor.prefetch` makes `.background` requests.
3. [x] **SyncEngine for lists.** Move the My PRs, History, and To Review
       refreshes and the timer into the engine. `PRMonitor` and the list views
       observe the store; notification and hook logic reacts to store changes.
       Shrink `PRMonitor` to settings, notifications, and hooks.
4. [x] **Pending changes, idempotent writes.** Add `pending_change`, the overlay
       function, the send loop, and the failed/retry UI. Move over task
       checkboxes (replacing `setTask`'s own chaining), title/body edits, file
       viewed, resolve thread, and reviewer add/remove.
5. [ ] **Pending changes, comments.** General comments, replies, and inline
       comments: they show right away as "sending", composers keep drafts until
       confirmed, and they aren't replayed after a restart.
6. [ ] **Pending changes, reviews.** Pending review start/add/submit/discard
       and submitted reviews. Merge-related actions stay direct calls (see
       above).

## Open questions

- Whether to normalize comments and review threads into their own tables (step 5
  may want per-thread updates), or keep blobs.
- Whether REST reads should send ETags (`If-None-Match`), which turns unchanged
  responses into 304s that don't count against the rate limit. This would be a
  follow-up to step 2.

## Log

- 2026-11-07: Step 1 done. GRDB 7.11.1 (exact pin); `LocalStore` in Application Support
  (`<bundle id>/Store.sqlite`) backs `PullRequestDetailCache` and the saved My PRs / To Review lists.
  `sync_state` is created but not written yet; step 2 fills it.
- 2026-11-07: Step 2 done. `SyncEngine` (actor) loads detail, comments, checks, and changed files into
  `PullRequestDetailCache` and records `sync_state`. `PullRequestDetailViewModel` asks it for data and shows
  the cache's `updates`; `PRMonitor.prefetch` makes `.background` requests (3 at a time). Design changes:
  `.changedFiles` takes the PR reference (to know where to save) instead of the repo; callers loading several
  resources use `start` to register the detail first, so comments and checks wait for it rather than being
  dropped; opening a PR passes a 30 s `maxAge`, so it joins or reuses a preload, while "Try Again" and
  refreshes after writes pass zero (see Dedupe above).
- 2026-11-07: Step 3 done. The engine loads `.openList`, `.history(page)`, `.reviewRequests` and `.currentUser`
  into `PullRequestListCache`, an in-memory copy of `pull_request_list` (now with `history:<page>` rows) that
  publishes `updates` like the details cache, plus each list's loading flag and error; `lastRefreshAt` comes from
  `sync_state`. `ListRefreshScheduler` owns the timer: ticks are `.background` with a `maxAge` of half the
  interval, which replaces `PRMonitor`'s "next refresh at". `PRMonitor` shows the cache, posts notifications and
  runs hooks when a list loads, and no longer fetches. Design changes: one backoff, measured in refresh intervals
  (see Backoff above), so a manual refresh during it sends nothing and keeps the last error; list refreshes that
  don't follow a write pass `joinsLoadInFlight`, so they share a load already sent; a list load superseded by a
  refresh after a write drops its result instead of saving it first, as `PRMonitor` did, so a merged row doesn't
  come back; a History page shows from the cache while it reloads; the SSO-authorization URL stays in memory.
- 2026-11-07: Step 4 done. `pending_change` (migration `addPendingChanges`) holds title, body (task boxes send the
  whole body), file viewed, resolve thread, and reviewer changes. `PullRequestDetailCache` keeps them beside the
  entries, `shownEntry` and `updates` apply them with `PendingChange.apply`, and `entry(for:)` stays GitHub's copy
  for the engine. `SyncEngine.sendPendingChanges` sends them; `PRMonitor` calls it on every list refresh, so changes
  left by the last run (including ones that were `sending`) and ones held by a backoff go out on start and on the
  next tick. Design changes: changes live in the details cache rather than a separate store, so the overlay and the
  confirm are one main-actor step; the refetched snapshot lands in the cache a step before the confirm (with the
  change still applied on top, so nothing flickers), and the confirm writes the entry row and deletes the
  `pending_change` row in one transaction; a refetch that fails applies the change to the snapshot instead of
  leaving it; a new change to a field also replaces a *failed* change to it, so Retry can't later send an older
  value; failed writes don't start the backoff (see above); title and reviewer changes refresh My PRs afterwards, as
  `PRMonitor` did. Credential change: pending changes are dropped (see above). `PRMonitor`'s `editPullRequest`,
  `setFileViewed`, `setReviewThreadResolved` and `setReviewRequested` are gone; the title and description editors
  close on Save, and failures show by what they changed with Retry and Discard.
