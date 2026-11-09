# Repository Instructions

- By default, whenever starting work on a new change or feature, use a new branch and create a pull request.
- Create regular (ready for review) pull requests, not draft pull requests. This overrides any user-level instruction to open drafts.
- After making changes, you may always commit and push them to the working branch without asking first.
- When creating a pull request, use `.github/pull_request_template.md` as the PR body template and fill out every section.
- Every time there are code changes:
  - Add or update the relevant test code as part of the change.
  - Run `mise run test` before building the app.
  - Rebuild and open the app for the user with `mise run build-and-open` after tests pass.
- Command-line tasks live in `mise.toml` and `mise-tasks/`. The `Makefile` only forwards `make <task>` to `mise run <task>`; do not add logic there.

## Development

- Open `GithubPanel.xcodeproj` and run the `GithubPanel` target, or use [mise](https://mise.jdx.dev) (`brew install mise`, then `mise trust` once). `mise tasks` lists every task.
- Common tasks: `mise run build`, `mise run build-and-open`, `mise run test`, `mise run clean`.
  - `build-and-open` quits the copy this checkout opened before; other checkouts and the installed app keep running.
  - `mise run test` uses a temporary settings file, so it never touches the real app's settings or other checkouts. It skips the scroll performance tests (results vary between runs); run those with `mise run test-performance`. It also dry-runs the release tasks.
  - `mise run run` launches the binary directly so Swift `print(...)` output shows in the terminal (`open` does not).
- The debug app is at `build/DerivedData/Build/Products/Debug/GithubPanel.app`.
- Short tasks are in `mise.toml`; longer ones are scripts in `mise-tasks/` sharing `scripts/lib.sh`. Set `DRY_RUN=1` on any build or release task to print its commands without running them.

### Mock PR states

`mise run mock` launches a debug build with fixture PRs (ready-to-merge, auto-merge on/off, merge queue, queued, failed, errored, waiting, draft, unknown) instead of calling GitHub; a `Mock GitHub PRs` banner shows when active. To make normal launches use mock data, run `defaults write io.github.ilstar.github-panel GithubPanel.useMockGitHubPRs -bool true`; undo it with `defaults delete io.github.ilstar.github-panel GithubPanel.useMockGitHubPRs`.

### Signing and local settings

mise loads `.env` (committed defaults), then `.env.local` (personal, git-ignored; dotenv syntax, quote values with spaces). Settings for `.env.local`:

- `GITHUB_PANEL_DEVELOPMENT_TEAM`: Apple Developer Team ID for local signing. Without it, builds use the repo's default local signing.
- `GITHUB_PANEL_DEVELOPER_ID_APPLICATION`: e.g. `"Developer ID Application: Your Name (TEAMID)"`, for distribution builds.
- `GITHUB_PANEL_NOTARY_PROFILE`: notarytool keychain profile, created once with `xcrun notarytool store-credentials githubpanel-notary`.
- `GITHUB_PANEL_SPARKLE_BIN`: the Sparkle `bin` directory (contains `generate_keys` and `generate_appcast`).

### Releases

- Env vars: `VERSION` (e.g. `1.4.0`), `BUILD_VERSION` (must increase every release), `BASE_BUILD_VERSION` (previous build number; `BUILD_VERSION` must be greater), and optional `RELEASE_TAG` (default `v$VERSION`), `RELEASE_TITLE`, `RELEASE_NOTES`, `GH_RELEASE_FLAGS`.
- `mise run dmg`: Developer ID signed, notarized, stapled DMG at `build/dist/GithubPanel-<VERSION>.dmg`.
- `mise run local-dmg`: unsigned DMG for this Mac only; Gatekeeper blocks it elsewhere.
- `mise run release`: builds the notarized DMG and creates or updates the GitHub release with the DMG and signed Sparkle `appcast.xml`. Needs `gh auth login`.
- Release tasks check signing, notarization, Sparkle, and `gh` settings before building, so missing settings fail fast.
- Example: `VERSION=1.4.0 BUILD_VERSION=6 BASE_BUILD_VERSION=5 RELEASE_NOTES="Release 1.4.0" mise run release`.

### Sparkle

Production builds update through Sparkle. Generate the signing key once with `$GITHUB_PANEL_SPARKLE_BIN/generate_keys`; keep the private key in the login Keychain and put only the public key in `GithubPanel/Info.plist`.
