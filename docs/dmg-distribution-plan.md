# DMG Distribution Plan

Goal: distribute GithubPanel outside the Mac App Store as a Developer ID signed, notarized DMG.

## Proposed Flow

1. Archive the app in Release mode with `xcodebuild archive`.
2. Export the archive with Developer ID signing.
3. Stage the exported app with an `/Applications` shortcut.
4. Create a compressed DMG.
5. Submit the DMG to Apple notarization.
6. Staple the notarization ticket to the DMG.
7. Verify the DMG with Gatekeeper.
8. Upload the DMG to GitHub Releases.

## Script Draft

The draft script lives at:

```bash
scripts/package-dmg.sh
```

It supports local unsigned-for-distribution testing:

```bash
scripts/package-dmg.sh --clean --skip-notarize
```

And notarized packaging once credentials are configured:

```bash
NOTARYTOOL_PROFILE=githubpanel-notary scripts/package-dmg.sh --clean
```

## Open Questions

- Confirm the Developer ID Application certificate is available locally.
- Confirm the Apple team ID and notarization credential profile name.
- Decide whether to keep the simple generated DMG or add a polished layout with a background image.
- Decide whether GitHub Releases is enough, or whether the app should later add Sparkle updates.
