# GithubPanel

A native macOS app for managing your GitHub pull requests: follow checks, review
code, comment, and merge without opening a browser.

<img width="1720" height="1278" alt="Screenshot 2026-09-27 at 10 25 25 AM" src="https://github.com/user-attachments/assets/d00424a1-bcb8-4e72-9848-435063efe037" />



## Features
- **Your pull requests in one place:** *My PRs* lists every open pull request you
  wrote, with a tag for its review state (approved, changes requested, awaiting
  review). *To Review* groups the ones waiting on your review by who asked, and
  shows each one's checks, size, and how long ago your review was requested.
  *History* shows what you recently merged or closed.
- **Check status and notifications:** checks refresh every 60 seconds by default
  (you can change this in Settings). A macOS notification appears when checks
  move from pending to success or failure, when someone approves or requests
  changes on your pull request, and when someone asks for your review. Click it
  to show the pull request in the app. If a refresh fails, the last list stays
  on screen with the error above it.
- **Merge from the list:** each row has the next action it needs, such as Merge,
  Mark ready, enable or disable auto-merge, or add to the merge queue. Merges use
  the repository's merge method (merge commit, squash, or rebase); pick another
  from the row's context menu. When a pull request can't merge, the button says
  why, such as a merge conflict or a missing approval.
- **Review others' pull requests:** the Review button (⌥⌘R) approves, comments,
  or requests changes on a pull request someone else wrote.
- **Pull request details:** select a pull request to see it on the right. The
  *Conversation* tab shows its Markdown description and comments. The *Files
  changed* tab shows the diff, with a file tree, a filter, viewed-file tracking,
  and unified or split views. If you wrote the pull request, you can edit its
  title and description in place.
- **Comments:** add general comments, start a review thread on any diff line,
  or reply in a thread. Comments post right away, not as part of a pending
  review.
- **Keyboard shortcuts:** most actions have one. **Help → Keyboard Shortcuts**
  (⌘/) lists them all, and a global shortcut shows or hides the app.
- Your GitHub token is stored in the Keychain.

## GitHub token scopes
- `repo` for private repositories.
- `public_repo` for public-only.

## Open in Xcode
Open `GithubPanel.xcodeproj` and run the `GithubPanel` target.

## Build from Terminal or VS Code
Command-line tasks run through [mise](https://mise.jdx.dev). Install it once with `brew install mise`, then trust the project config:

```bash
cd github-panel
mise trust
```

List the available tasks with:

```bash
mise tasks
```

Build the app with:

```bash
mise run build
```

Build and open the app with:

```bash
mise run build-and-open
```

Run the unit tests with:

```bash
mise run test
```

`mise run test` skips the scroll performance tests because their results vary between runs. Run them on their own with:

```bash
mise run test-performance
```

`make build`, `make test`, and other `make <task>` commands still work. The `Makefile` forwards them to `mise run <task>`.

Short tasks are defined in `mise.toml`. Longer tasks are scripts in `mise-tasks/` that share `scripts/lib.sh`. `mise run test` also dry-runs the release tasks to check the commands they would run. Set `DRY_RUN=1` on any build or release task to print its commands without running them:

```bash
DRY_RUN=1 VERSION=1.4.0 BUILD_VERSION=6 mise run release
```

The debug app is created at:

```bash
build/DerivedData/Build/Products/Debug/GithubPanel.app
```

To run it and see Swift `print(...)` output in the terminal, launch the app binary directly:

```bash
mise run run
```

Launching with `open GithubPanel.app` works for normal app testing, but `print(...)` output will not usually appear in your current terminal because macOS starts the app separately.

## Releases
Release tasks read their settings from environment variables:

- `VERSION`: the user-facing version, for example `1.4.0`.
- `BUILD_VERSION`: the bundle build number. It must increase with every release.
- `BASE_BUILD_VERSION`: the previous release's build number. `BUILD_VERSION` must be greater than it.
- `RELEASE_TAG`, `RELEASE_TITLE`, `RELEASE_NOTES`, `GH_RELEASE_FLAGS`: optional GitHub release metadata. The tag defaults to `v$VERSION`.

Create a Developer ID signed, notarized, stapled DMG that can be shared with another Mac:

```bash
VERSION=1.4.0 BUILD_VERSION=6 BASE_BUILD_VERSION=5 mise run dmg
```

The DMG is created at `build/dist/GithubPanel-<VERSION>.dmg`.

For a quick unsigned DMG that stays on your development Mac, use:

```bash
VERSION=1.4.0 mise run local-dmg
```

Do not send `local-dmg` output to another Mac. Gatekeeper may block it with "Apple could not verify" because it is intentionally not notarized.

Create or update a GitHub release with the DMG attached:

```bash
VERSION=1.4.0 BUILD_VERSION=6 BASE_BUILD_VERSION=5 RELEASE_NOTES="Release 1.4.0" mise run release
```

This requires the GitHub CLI to be installed and authenticated with `gh auth login`. It uploads both the notarized DMG and the signed Sparkle `appcast.xml`. Override the release metadata when needed:

```bash
VERSION=1.4.0 BUILD_VERSION=6 BASE_BUILD_VERSION=5 RELEASE_TITLE="GithubPanel 1.4.0" GH_RELEASE_FLAGS="--draft" mise run release
```

Release tasks check the signing, notarization, Sparkle, and `gh` settings before building, so a missing setting fails right away instead of after notarization.

## Signing
The checked-in project is configured for local development builds without a committed Apple Developer Team ID.

mise loads `.env` (committed defaults) and then `.env.local` (your settings, ignored by Git). Both use dotenv syntax, so quote values that contain spaces.

For personal development, add your Apple Developer Team ID to `.env.local`:

```bash
GITHUB_PANEL_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
GITHUB_PANEL_SPARKLE_BIN="/path/to/Sparkle/bin"
```

Then use the normal build commands:

```bash
mise run test
mise run build-and-open
```

When `.env.local` sets `GITHUB_PANEL_DEVELOPMENT_TEAM`, the build tasks pass local signing settings to Xcode. Without `.env.local`, builds use the repo's default local signing behavior.

For distribution builds, add your Developer ID Application identity and a notarytool keychain profile to `.env.local`:

```bash
GITHUB_PANEL_DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)"
GITHUB_PANEL_NOTARY_PROFILE="githubpanel-notary"
```

Create the notary profile once with:

```bash
xcrun notarytool store-credentials githubpanel-notary
```

`mise run release` uses the notarized DMG so uploaded releases pass Gatekeeper on other Macs.

## Automatic updates

GithubPanel uses Sparkle to check for updates in production builds. It downloads signed updates in the background and asks before relaunching to install one. The application menu also includes `Check for Updates…`.

Generate the Sparkle signing key once using the tool included with the resolved Sparkle package:

```bash
/path/to/Sparkle/bin/generate_keys
```

Keep the private key in the macOS login Keychain. Only the generated public key belongs in `GithubPanel/Info.plist`. Set `GITHUB_PANEL_SPARKLE_BIN` in `.env.local` to the directory containing `generate_appcast` before running `mise run release`.

Versions through v1.2.1 do not contain Sparkle and cannot update themselves. Install the first Sparkle-enabled release manually; later releases update from inside the app.

## Mock PR States
Debug builds can show fixture PRs for visual testing instead of calling GitHub. Build with the command above, then launch with:

```bash
mise run mock
```

The mock list includes PRs for ready-to-merge, enable auto-merge, disable auto-merge, merge queue, queued, failed, errored, waiting, draft, and unknown states. A `Mock GitHub PRs` banner appears at the top of the app when mock data is active.

To make normal launches of the debug app use mock data:

```bash
defaults write com.githubpanel.app GithubPanel.useMockGitHubPRs -bool true
mise run open
```

To turn the persistent mock setting off:

```bash
defaults delete com.githubpanel.app GithubPanel.useMockGitHubPRs
```

To clean the command-line build output:

```bash
mise run clean
```
