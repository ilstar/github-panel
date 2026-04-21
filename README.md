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

## Release and Notarization
Release builds are signed with `Developer ID Application`, packaged as a zip, submitted to Apple's notary service, stapled, and repackaged.

Before running a release build, install a `Developer ID Application` certificate for your team in Keychain.

Add release settings to `.env.local`:

```makefile
GITHUB_PANEL_DEVELOPMENT_TEAM = YOUR_TEAM_ID
GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM = YOUR_TEAM_ID
GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE = githubpanel-notary
GITHUB_PANEL_NOTARY_APPLE_ID = you@example.com
```

`GITHUB_PANEL_RELEASE_DEVELOPMENT_TEAM` defaults to `GITHUB_PANEL_DEVELOPMENT_TEAM` if omitted.

Store notary credentials once:

```bash
make notary-store-credentials
```

Build the signed release zip:

```bash
make release
```

Submit, staple, validate, and package the notarized zip:

```bash
make notarize
```

The release artifacts are created under `build/Release/`.

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
