# GithubPanel

A native macOS app for managing your GitHub pull requests: follow checks, review
code, comment, and merge without opening a browser.

<img width="1929" height="1285" alt="Screenshot 2026-11-08 at 4 15 42 PM" src="https://github.com/user-attachments/assets/5dd929bc-a454-45ee-8130-4ba987679841" />

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
- **Secure token storage:** your GitHub token is stored in the Keychain.

## Install
1. Download the latest `GithubPanel-<version>.dmg` from
   [Releases](https://github.com/ilstar/github-panel/releases/latest). Requires
   macOS 13 or later.
2. Open the DMG and drag GithubPanel to Applications.
3. Launch the app, then paste a GitHub personal access token when asked. You can
   change it later in Settings.

## GitHub token scopes
- `repo` for private repositories.
- `public_repo` for public-only.

## Updates
The app checks for updates on its own, downloads them in the background, and
asks before relaunching to install one. You can also choose
**GithubPanel → Check for Updates…**.

Versions through v1.2.1 can't update themselves. Install a newer release
manually once; later releases update from inside the app.
