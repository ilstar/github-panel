# GithubPanel

Mini macOS app to monitor your active GitHub pull request checks.

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

Then use the local signed build targets:

```bash
make test-local-signed
make build-and-open-local-signed
```

`.env.local` is ignored so your Team ID stays out of Git. For release builds, use your own Developer ID signing setup outside the repository.

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
