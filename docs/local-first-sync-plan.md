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
- One database file in Application Support (`GithubPanel/Store.sqlite`), since
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
  running one, and a higher priority raises it.
- **Priority**: `.userVisible` (the PR or list the user is looking at) runs before
  `.background` (timer refresh, prefetch). Background requests run a few at a
  time, so they never hold up a user request.
- **Freshness**: `sync_state.fetchedAt` per resource. A request newer than a
  caller-given `maxAge` is skipped. Views can show how stale data is.
- **Backoff**: the throttled/auth backoff moves here from `PRMonitor` and applies
  to every request.
- Results go into `LocalStore` in one transaction per response. The engine never
  touches views or view models.

### Pending changes (optimistic writes)

What the UI shows = **the last server snapshot + pending changes applied on
top**. Pending changes live in `pending_change`. A pure function per change
kind (`apply(_ change, to: entry)`) builds what the view renders, so a background
refresh landing mid-write can't make the UI flicker back.

- The engine sends a PR's changes one at a time, in order.
- On success, it refetches the affected resource, then writes the new snapshot
  and deletes the change **in the same transaction**.
- On failure, the change becomes `failed` with its error. The view shows it
  inline with Retry / Discard. Composers keep their draft until the change is
  confirmed.
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

1. [ ] **LocalStore behind today's caches.** Add GRDB and `LocalStore` with
       migrations and the `pull_request_detail`, `pull_request_list`, and
       `sync_state` tables. Back `PullRequestDetailCache` and the saved PR lists
       with it, keeping their public interfaces (`entry`, `store`,
       `needsRefresh`, `removeAll`, `updates`, `waitForRestore`, `saveNow`). Drop
       the old `PullRequestDetails.json` and the list keys in defaults. Don't
       import their contents; they're only caches. Callers don't change.
2. [ ] **SyncEngine for PR details.** Add `SyncEngine` with dedupe, priority,
       `sync_state` freshness, and backoff. Move detail, comments, checks, and
       changed-files fetches into it. `PullRequestDetailViewModel` observes the
       store and calls `engine.request(...)` instead of its fetch closures.
       `PRMonitor.prefetch` makes `.background` requests.
3. [ ] **SyncEngine for lists.** Move the My PRs, History, and To Review
       refreshes and the timer into the engine. `PRMonitor` and the list views
       observe the store; notification and hook logic reacts to store changes.
       Shrink `PRMonitor` to settings, notifications, and hooks.
4. [ ] **Pending changes, idempotent writes.** Add `pending_change`, the overlay
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
