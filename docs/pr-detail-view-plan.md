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
- **UI**: a separate window per PR (`WindowGroup(for: PullRequestReference.self)`),
  so the main panel stays small. The window has a header and two tabs:
  *Conversation* (description) and *Files changed* (diff).
- **Mock mode**: `MockGitHubAPI` returns a fixture detail and diff, so
  `mise run mock` shows the window without a token.

## Steps

Status: `[ ]` todo · `[~]` in progress · `[x]` done

1. [x] Models + diff parser, with tests.
2. [x] API: fetch PR detail and files (`GitHubAPIClient`, `GitHubAPI`, mock, test fake), with tests.
3. [ ] `PullRequestDetailViewModel` + `PRMonitor.fetchPullRequestDetail`, with tests.
4. [ ] Detail window: header (title, number, author, branches, state, +/−) and
       Conversation tab showing the description.
5. [ ] Files changed tab: file list and a colored, line-numbered diff per file.
6. [ ] Open the detail window from the Open and History lists (click / Return);
       keep "Open on GitHub" in the window and on ⌘-click.
7. [ ] Mock fixtures for the detail window; README update.
8. [ ] Open a draft PR.

## Later (not in this branch unless time allows)

- Better Markdown rendering for the description (block elements, code blocks, images).
- Checks list with each check's status and a link to its logs.
- Commits tab.
- Reviews and comments timeline; inline review comments on the diff.
- Syntax highlighting; split (side-by-side) diff; collapsing large files.
- Files over GitHub's `patch` size limit (fetch the raw diff instead).
- Pagination for PRs with more than 100 changed files.

## Log

- 2026-09-25: Plan written.
