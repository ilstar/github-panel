#!/usr/bin/env bash
set -euo pipefail

APP_NAME="GithubPanel"
SCHEME="GithubPanel"
PROJECT="GithubPanel.xcodeproj"
CONFIGURATION="Release"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/distribution"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
DMG_STAGING_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
EXPORT_OPTIONS_PATH="$BUILD_DIR/ExportOptions.plist"

print_usage() {
    cat <<EOF
Usage: scripts/package-dmg.sh [options]

Builds, exports, packages, and optionally notarizes GithubPanel as a DMG.

Options:
  --skip-notarize        Create the DMG without notarizing it.
  --clean               Remove previous distribution output before building.
  --help                Show this help text.

Notarization:
  Preferred:
    xcrun notarytool store-credentials githubpanel-notary \\
      --apple-id "you@example.com" \\
      --team-id "TEAMID1234" \\
      --password "app-specific-password"

    NOTARYTOOL_PROFILE=githubpanel-notary scripts/package-dmg.sh

  Or use environment variables:
    APPLE_ID="you@example.com" \\
    TEAM_ID="TEAMID1234" \\
    NOTARYTOOL_PASSWORD="app-specific-password" \\
    scripts/package-dmg.sh

Output:
  build/distribution/$APP_NAME.dmg
EOF
}

SKIP_NOTARIZE=0
CLEAN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-notarize)
            SKIP_NOTARIZE=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            print_usage >&2
            exit 1
            ;;
    esac
done

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2
        exit 1
    fi
}

require_tool xcodebuild
require_tool hdiutil
require_tool xcrun

cd "$ROOT_DIR"

if [[ "$CLEAN" -eq 1 ]]; then
    rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

cat > "$EXPORT_OPTIONS_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>96R567F55V</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
EOF

echo "Archiving $APP_NAME..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -archivePath "$ARCHIVE_PATH"

echo "Exporting Developer ID app..."
rm -rf "$EXPORT_PATH"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
    -exportPath "$EXPORT_PATH"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Expected exported app not found: $APP_PATH" >&2
    exit 1
fi

echo "Creating DMG..."
rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
cp -R "$APP_PATH" "$DMG_STAGING_DIR/"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
rm -f "$DMG_PATH"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
    echo "Skipping notarization."
else
    echo "Submitting DMG for notarization..."
    if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --wait
    elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${NOTARYTOOL_PASSWORD:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$NOTARYTOOL_PASSWORD" \
            --wait
    else
        cat >&2 <<EOF
Missing notarization credentials.

Either set NOTARYTOOL_PROFILE, or set APPLE_ID, TEAM_ID, and NOTARYTOOL_PASSWORD.
Use --skip-notarize to create an unsigned-for-distribution DMG for local testing.
EOF
        exit 1
    fi

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_PATH"
fi

echo "Verifying DMG..."
spctl -a -vv -t open "$DMG_PATH" || {
    if [[ "$SKIP_NOTARIZE" -eq 1 ]]; then
        echo "DMG verification failed because notarization was skipped."
    else
        exit 1
    fi
}

echo "Done: $DMG_PATH"
