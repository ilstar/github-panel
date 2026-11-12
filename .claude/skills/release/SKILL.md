---
name: release
description: Release a new GithubPanel version — pull main, bump the version and build number, test, build, push the bump to main, publish the notarized DMG and Sparkle appcast with `mise run release`, and write user-facing release notes. Use when the user says "release", "new release", "release a new version", "cut a release", or "bump version".
---

# Release GithubPanel

A release is a version bump commit on `main` plus a GitHub release `vX.Y.Z` that holds the notarized DMG and the Sparkle `appcast.xml`. Installed apps update through Sparkle, which compares **build numbers** (`CFBundleVersion`), so the build number must go up by one every release.

## What the user's words mean

- **"release"**, "new release", "release a new version": do every step below, then report.
- **"bump version"** alone: do steps 1–5 (bump, test, build, push), then ask whether to publish before running step 6.
- Version bump commits go straight to `main` without a PR. Every release since 2.2.0 has been done this way.

## Steps

Keep logs and notes in the session scratchpad, not the repo. `$S` below stands for that directory.

### 1. Pull and inspect

```bash
git status --short                      # must be clean
git switch main
git pull --ff-only origin main
git fetch -q --tags origin
LAST_TAG=$(gh release list --limit 1 --json tagName -q '.[0].tagName')
git log --oneline "$LAST_TAG"..HEAD     # what this release ships
```

If nothing user-facing landed since `$LAST_TAG`, tell the user and ask before releasing.

### 2. Pick the version

- **Minor** (`2.24.0` → `2.25.0`) is the default. Use it when any new feature or visible change landed.
- **Patch** (`2.24.0` → `2.24.1`) when there are no new features: only fixes, or only removing a feature.
- **Major**, or a specific version: only when the user asks.

The build number is always the current one plus one.

### 3. Make sure the tag is free

```bash
gh release view "v$NEW_VERSION" >/dev/null 2>&1 && echo "RELEASE EXISTS"
git ls-remote --tags origin "v$NEW_VERSION"
```

If either finds something, **stop and ask**. `mise run release` doesn't fail on an existing release. It uploads the new files into it with `--clobber` and keeps the old tag, which may point at an older commit, and the old date. That happened with v2.21.0, and it was fixed by releasing 2.22.0.

### 4. Bump the version

The version lives in two files:

- `GithubPanel.xcodeproj/project.pbxproj`: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`, two occurrences each. The other `CURRENT_PROJECT_VERSION = 1` lines belong to the test target; leave them alone.
- `scripts/lib.sh`: `VERSION`, `BUILD_VERSION`, and `BASE_BUILD_VERSION`, where the base is the previous build.

```bash
OLD_VERSION=$(sed -n 's/^VERSION="${VERSION:-\(.*\)}"$/\1/p' scripts/lib.sh)
OLD_BUILD=$(sed -n 's/^BUILD_VERSION="${BUILD_VERSION:-\(.*\)}"$/\1/p' scripts/lib.sh)
OLD_BASE=$(sed -n 's/^BASE_BUILD_VERSION="${BASE_BUILD_VERSION:-\(.*\)}"$/\1/p' scripts/lib.sh)
NEW_BUILD=$((OLD_BUILD + 1))
# NEW_VERSION was chosen in step 2

sed -i '' \
  -e "s/CURRENT_PROJECT_VERSION = $OLD_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/" \
  -e "s/MARKETING_VERSION = $OLD_VERSION;/MARKETING_VERSION = $NEW_VERSION;/" \
  GithubPanel.xcodeproj/project.pbxproj
sed -i '' \
  -e "s/^VERSION=\"\${VERSION:-$OLD_VERSION}\"/VERSION=\"\${VERSION:-$NEW_VERSION}\"/" \
  -e "s/^BUILD_VERSION=\"\${BUILD_VERSION:-$OLD_BUILD}\"/BUILD_VERSION=\"\${BUILD_VERSION:-$NEW_BUILD}\"/" \
  -e "s/^BASE_BUILD_VERSION=\"\${BASE_BUILD_VERSION:-$OLD_BASE}\"/BASE_BUILD_VERSION=\"\${BASE_BUILD_VERSION:-$OLD_BUILD}\"/" \
  scripts/lib.sh

grep -n -E 'MARKETING_VERSION = |CURRENT_PROJECT_VERSION = ' GithubPanel.xcodeproj/project.pbxproj
sed -n '/^VERSION=/,/^BASE_BUILD_VERSION=/p' scripts/lib.sh
git diff --stat   # expect 2 files, 4 + 3 changed lines
```

### 5. Test, build, push

```bash
mise run test > "$S/test-$NEW_VERSION.log" 2>&1; echo "exit=$?"
grep -E 'Executed .* tests' "$S/test-$NEW_VERSION.log" | tail -1

mise run build-and-open > "$S/build-$NEW_VERSION.log" 2>&1; echo "exit=$?"
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" -c "Print CFBundleVersion" \
  build/DerivedData/Build/Products/Debug/GithubPanel.app/Contents/Info.plist

git add GithubPanel.xcodeproj/project.pbxproj scripts/lib.sh
git commit -m "Bump version to $NEW_VERSION"
git push origin main
```

If a test fails, find which one with `xcrun xcresulttool get test-results summary --path <newest .xcresult under build/DerivedData/Logs/Test>`.
- `PullRequestEditorFocusTests/testTitleEditorTakesFocusWhenItOpens` is known to be flaky. Rerun it before treating it as a real failure.
- "Test runner exited early" usually means the app was quit during the run. Rerun.
- Anything else: stop and report it. Don't release.

### 6. Draft the notes, then publish

Write the notes to `$S/notes-$NEW_VERSION.md` before publishing, so the release goes out with them instead of the "Release X.Y.Z" placeholder. Notes are for app users:

- Start with one sentence: `GithubPanel X.Y <does A, B, and C>.`
- Follow with bullets of the form `- **Short name:** what changed, from the user's point of view.`
- Put **bold** around UI labels, menu items, and button names.
- Leave out refactors, tests, docs, and CI unless they change what users see or feel. Speed-ups count.
- Don't invent numbers or behavior. If a commit title is unclear, read the PR (`gh pr view <n>`).

Notarization takes several minutes, so run the release in the background and wait for it to finish:

```bash
RELEASE_NOTES="$(cat "$S/notes-$NEW_VERSION.md")" mise run release > "$S/release-$NEW_VERSION.log" 2>&1
echo "release exit=$?" >> "$S/release-$NEW_VERSION.log"
```

If the release already went out with placeholder notes, fix them with `gh release edit "v$NEW_VERSION" --notes-file "$S/notes-$NEW_VERSION.md"`.

### 7. Verify

```bash
grep -nE 'dmg: accepted|Notarized Developer ID|Creating GitHub release|existing GitHub release' "$S/release-$NEW_VERSION.log"
gh api "repos/ilstar/github-panel/releases/tags/v$NEW_VERSION" \
  --jq '{created_at, published_at, target_commitish, assets: [.assets[] | "\(.name) \(.created_at)"]}'
git ls-remote --tags origin "v$NEW_VERSION"; git rev-parse HEAD   # must match
gh release list --limit 2                                          # new one is Latest
grep -E 'sparkle:version|shortVersionString' build/dist/appcast.xml
```

Check all of these:
- The log says **Creating GitHub release**, not "existing GitHub release".
- The DMG was accepted with `source=Notarized Developer ID`.
- The tag points at the bump commit.
- The release has two assets: `GithubPanel-X.Y.Z.dmg` and `appcast.xml`.
- `sparkle:version` is the new build number.

### 8. Report

Report times in Pacific Time, never UTC. GitHub's `created_at` is the date of the tagged commit, not when the release was made. `published_at` is when it went out. To convert:

```bash
TZ=America/Los_Angeles date -r "$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$TS" +%s)" '+%b %-d, %-I:%M %p %Z'
```

Give the user:
- The release link
- The version and build
- The bump commit
- The test count
- The notarization result
- The publish time in PT
- The assets
- A one-line summary of the notes
