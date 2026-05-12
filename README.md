# GithubPanel

Mini macOS app to monitor your active GitHub pull request checks.

<img width="853" height="818" alt="Screenshot 2026-04-19 at 4 48 56 PM" src="https://github.com/user-attachments/assets/e35838c2-0bd1-4f66-bb9b-d9c6be2cd482" />


## How it works
- Stores a GitHub token in Keychain.
- Finds your most recently updated open PR (authored by you).
- Polls check status every 60 seconds.
- Sends a macOS notification when checks move from pending to success or failure.
- Clicking the notification opens the PR in the browser.

## GitHub token scopes
- `repo` for private repositories.
- `public_repo` for public-only.

## Open in Xcode
Open `GithubPanel.xcodeproj` and run the `GithubPanel` target.

## Build from Terminal or VS Code
You can edit the app in VS Code or another editor and build it with `make`:

```bash
cd github-panel
make build
```

Build and open the app with:

```bash
make build-and-open
```

Run the unit tests with:

```bash
make test
```

Create a release DMG with:

```bash
make dmg VERSION=1.0
```

The DMG is created at:

```bash
build/dist/GithubPanel-1.0.dmg
```

This creates a Developer ID signed, notarized, stapled DMG suitable for sharing with another Mac. It uses the same distribution flow as:

```bash
make notarized-dmg VERSION=1.0
```

For a quick unsigned DMG that stays on your development Mac, use:

```bash
make local-dmg VERSION=1.0
```

Do not send `local-dmg` output to another Mac. Gatekeeper may block it with "Apple could not verify" because it is intentionally not notarized.

Create or update a GitHub release with the DMG attached:

```bash
make release VERSION=1.0 RELEASE_NOTES="Release 1.0"
```

This requires the GitHub CLI to be installed and authenticated with `gh auth login`.
By default, `make release` uses the tag `v1.0` when `VERSION=1.0`. Override the release metadata when needed:

```bash
make release VERSION=1.1.0 RELEASE_TAG=v1.1.0 RELEASE_TITLE="GithubPanel 1.1.0" GH_RELEASE_FLAGS="--draft"
```

The debug app is created at:

```bash
build/DerivedData/Build/Products/Debug/GithubPanel.app
```

To run it and see Swift `print(...)` output in the terminal, launch the app binary directly:

```bash
make run
```

Launching with `open GithubPanel.app` works for normal app testing, but `print(...)` output will not usually appear in your current terminal because macOS starts the app separately.

## Signing
The checked-in project is configured for local development builds without a committed Apple Developer Team ID.

For personal development, add your Apple Developer Team ID to `.env.local`:

```makefile
GITHUB_PANEL_DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Then use the normal build commands:

```bash
make test
make build-and-open
```

When `.env.local` sets `GITHUB_PANEL_DEVELOPMENT_TEAM`, `make` passes local signing settings to Xcode. Without `.env.local`, builds use the repo's default local signing behavior. `.env.local` is ignored so your Team ID stays out of Git.

For distribution builds, add your Developer ID Application identity and a notarytool keychain profile to `.env.local`:

```makefile
GITHUB_PANEL_DEVELOPER_ID_APPLICATION = Developer ID Application: Your Name (TEAMID)
GITHUB_PANEL_NOTARY_PROFILE = githubpanel-notary
```

Create the notary profile once with:

```bash
xcrun notarytool store-credentials githubpanel-notary
```

Then build the shareable DMG:

```bash
make notarized-dmg VERSION=1.0
```

`make release` uses the notarized DMG so uploaded releases pass Gatekeeper on other Macs.

## Mock PR States
Debug builds can show fixture PRs for visual testing instead of calling GitHub. Build with the command above, then launch with:

```bash
make mock
```

The mock list includes PRs for ready-to-merge, enable auto-merge, disable auto-merge, merge queue, queued, failed, errored, waiting, draft, and unknown states. A `Mock GitHub PRs` banner appears at the top of the app when mock data is active.

To make normal launches of the debug app use mock data:

```bash
defaults write com.githubpanel.app GithubPanel.useMockGitHubPRs -bool true
make open
```

To turn the persistent mock setting off:

```bash
defaults delete com.githubpanel.app GithubPanel.useMockGitHubPRs
```

To clean the command-line build output:

```bash
make clean
```
