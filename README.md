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
Open `/Users/fred/Documents/github-panel/GithubPanel.xcodeproj` and run the `GithubPanel` target.

## Build from Terminal or VS Code
You can edit the app in VS Code or another editor and build it with `xcodebuild`:

```bash
cd /Users/fred/Documents/github-panel

xcodebuild \
  -project GithubPanel.xcodeproj \
  -scheme GithubPanel \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  build
```

Run the unit tests with:

```bash
xcodebuild \
  -project GithubPanel.xcodeproj \
  -scheme GithubPanel \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  test
```

The debug app is created at:

```bash
/Users/fred/Documents/github-panel/build/DerivedData/Build/Products/Debug/GithubPanel.app
```

To run it and see Swift `print(...)` output in the terminal, launch the app binary directly:

```bash
/Users/fred/Documents/github-panel/build/DerivedData/Build/Products/Debug/GithubPanel.app/Contents/MacOS/GithubPanel
```

Launching with `open GithubPanel.app` works for normal app testing, but `print(...)` output will not usually appear in your current terminal because macOS starts the app separately.

## Mock PR States
Debug builds can show fixture PRs for visual testing instead of calling GitHub. Build with the command above, then launch with:

```bash
open -n /Users/fred/Documents/github-panel/build/DerivedData/Build/Products/Debug/GithubPanel.app --args --mock-github-prs
```

The mock list includes PRs for ready-to-merge, enable auto-merge, disable auto-merge, merge queue, queued, failed, errored, waiting, draft, and unknown states. A `Mock GitHub PRs` banner appears at the top of the app when mock data is active.

To make normal launches of the debug app use mock data:

```bash
defaults write com.githubpanel.app GithubPanel.useMockGitHubPRs -bool true
open -n /Users/fred/Documents/github-panel/build/DerivedData/Build/Products/Debug/GithubPanel.app
```

To turn the persistent mock setting off:

```bash
defaults delete com.githubpanel.app GithubPanel.useMockGitHubPRs
```

To clean the command-line build output:

```bash
xcodebuild \
  -project GithubPanel.xcodeproj \
  -scheme GithubPanel \
  -derivedDataPath build/DerivedData \
  clean
```
