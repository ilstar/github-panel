# Pull Request Detail View — Plan

Goal: open a pull request inside the app and read it there — description,
changed files, and the code diff — instead of jumping to github.com. Start
small; add GitHub features one at a time.

Branch: `fred/pr-detail-view`

## Design

- **Data**: GitHub REST.
  - `GET /repos/{owner}/{repo}/pulls/{number}` for the title, body, author,
    branches, state, and line counts.
  - `GET /repos/{owner}/{repo}/pulls/{number}/files` for the changed files and
    each file's `patch` (unified diff hunks).
- **Models**: `PullRequestDetail`, `PullRequestFile`, and a `DiffParser` that
  turns a `patch` string into typed lines with old/new line numbers.
- **State**: `PullRequestDetailViewModel` (`@MainActor`, `ObservableObject`)
  loads the detail and files through a fetch closure that `PRMonitor` provides,
  so the token stays inside `PRMonitor` and the view model is easy to test.
- **UI**: split view in the main window — PR list on the left, the selected
  PR's detail on the right (changed from a separate window at the user's
  request). The detail pane has a header and two tabs: *Conversation*
  (description) and *Files changed* (diff). A row's context menu can still open
  a PR in its own window.
- **Mock mode**: `MockGitHubAPI` returns a fixture detail and diff, so
  `mise run mock` shows the window without a token. (Done in step 2.)

## Steps

Status: `[ ]` todo · `[~]` in progress · `[x]` done

1. [x] Models + diff parser, with tests.
2. [x] API: fetch PR detail and files (`GitHubAPIClient`, `GitHubAPI`, mock, test fake), with tests.
3. [x] `PullRequestDetailViewModel` + `PRMonitor.fetchPullRequestDetail`, with tests.
4. [x] Detail window: header (title, number, author, branches, state, +/−) and
       Conversation tab showing the description (inline Markdown only).
5. [x] Show the selected PR from the Open and History lists. Clicking a row
       selects it; ⌘-click and Return open GitHub; the context menu offers
       "Open in New Window" and "Open on GitHub".
6. [x] Files changed tab: file list and a colored, line-numbered diff per file.
6b. [x] Split layout: list on the left, detail on the right.
7. [x] Block-level Markdown for the description (headings, lists, code blocks, quotes).
8. [x] README update; open a draft PR.

## Later (not in this branch unless time allows)

- Images, tables, and task lists in the description.
- Cache loaded details so switching between PRs does not refetch each time.
- Auto-refresh the detail pane when the list refresh sees a new head SHA.
- Checks list with each check's status and a link to its logs.
- Commits tab.
- Reviews timeline (review summaries and approvals) on the Conversation tab.
- Resolve/unresolve review threads; multi-line and file-level comments; pending reviews.
- Syntax highlighting; split (side-by-side) diff; collapsing large files.
- Files over GitHub's `patch` size limit (fetch the raw diff instead).
- Pagination for PRs with more than 100 changed files.

## Log

- 2026-09-25: Plan written.
- 2026-09-25: Steps 1–5 done. Moved "open from lists" ahead of the diff view so
  each UI step can be tried in the app. The sandbox here has no screen-recording
  or accessibility access, so UI checks are offscreen renders plus a manual look.
- 2026-09-25: Switched to a list/detail split view. Checked the layout with an
  offscreen render of `ContentView` and `PullRequestFilesView` (mock data).
- 2026-09-26: Comments (branch `fred/pr-commenting`). General comments are
  issue comments; inline comments are review threads. Loaded with one GraphQL
  query (first 100 comments and threads). Posted through REST so each comment
  is published right away: `POST /issues/{n}/comments`,
  `POST /pulls/{n}/comments` (with `commit_id`, `path`, `line`, `side`), and
  `POST /pulls/{n}/comments/{id}/replies`.
