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
