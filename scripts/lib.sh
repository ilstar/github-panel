# shellcheck shell=bash
# Shared settings and helpers for the mise tasks in mise-tasks/.
# Source this file from a task; do not run it directly.
#
# Every setting can be overridden from the environment, e.g.
#   VERSION=1.4.0 BUILD_VERSION=6 mise run release
# Set DRY_RUN=1 to print commands instead of running them.

set -euo pipefail

ROOT="${MISE_PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

PROJECT="$ROOT/GithubPanel.xcodeproj"
SCHEME=GithubPanel
APP_NAME=GithubPanel
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA="$ROOT/build/DerivedData"

VERSION="${VERSION:-1.3.1}"
BUILD_VERSION="${BUILD_VERSION:-5}"
BASE_BUILD_VERSION="${BASE_BUILD_VERSION:-4}"

DIST_DIR="$ROOT/build/dist"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
APP_ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
APPCAST_PATH="$DIST_DIR/appcast.xml"
APPCAST_STAGING="$DIST_DIR/appcast-staging"

RELEASE_TAG="${RELEASE_TAG:-v$VERSION}"
RELEASE_TITLE="${RELEASE_TITLE:-$APP_NAME $VERSION}"
RELEASE_NOTES="${RELEASE_NOTES:-Release $VERSION}"
GH_RELEASE_FLAGS="${GH_RELEASE_FLAGS:-}"

DEVELOPER_ID_APPLICATION="${GITHUB_PANEL_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${GITHUB_PANEL_NOTARY_PROFILE:-${GITHUB_PANEL_NOTARY_KEYCHAIN_PROFILE:-}}"
SPARKLE_BIN="${GITHUB_PANEL_SPARKLE_BIN:-}"

# app_path <configuration>
app_path() {
  echo "$DERIVED_DATA/Build/Products/$1/$APP_NAME.app"
}

dry_run() {
  [[ "${DRY_RUN:-}" == 1 ]]
}

# run <command...>: echo the command, then run it unless DRY_RUN=1.
run() {
  echo "+ $*"
  dry_run || "$@"
}

fail() {
  echo "$*" >&2
  exit 1
}

# xcodebuild_app <configuration> <action> [xcodebuild args...]
xcodebuild_app() {
  local args=(
    -project "$PROJECT"
    -scheme "$SCHEME"
    -configuration "$1"
    -derivedDataPath "$DERIVED_DATA"
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_VERSION"
  )
  if [[ -n "${GITHUB_PANEL_DEVELOPMENT_TEAM:-}" ]]; then
    args+=(
      DEVELOPMENT_TEAM="$GITHUB_PANEL_DEVELOPMENT_TEAM"
      CODE_SIGN_IDENTITY="${GITHUB_PANEL_CODE_SIGN_IDENTITY:-}"
      CODE_SIGN_STYLE=Automatic
    )
  fi
  run xcodebuild "${args[@]}" "${@:2}"
}

# Checked before a release build starts so a missing setting fails fast
# instead of after notarization.
require_distribution_signing() {
  dry_run && return
  [[ -n "$DEVELOPER_ID_APPLICATION" ]] ||
    fail "Set GITHUB_PANEL_DEVELOPER_ID_APPLICATION in .env.local, for example: Developer ID Application: Your Name (TEAMID)"
  [[ -n "$NOTARY_PROFILE" ]] ||
    fail "Set GITHUB_PANEL_NOTARY_PROFILE in .env.local after running: xcrun notarytool store-credentials <profile-name>"
}

require_sparkle_tools() {
  dry_run && return
  [[ -x "$SPARKLE_BIN/generate_appcast" ]] ||
    fail "Set GITHUB_PANEL_SPARKLE_BIN in .env.local to Sparkle's bin directory"
}

require_gh() {
  dry_run && return
  command -v gh >/dev/null || fail "GitHub CLI is required. Install gh and run gh auth login."
}

require_newer_build_version() {
  ((BUILD_VERSION > BASE_BUILD_VERSION)) ||
    fail "BUILD_VERSION $BUILD_VERSION must be greater than BASE_BUILD_VERSION $BASE_BUILD_VERSION"
}

validate_built_version() {
  dry_run && return

  local plist actual
  plist="$(app_path Release)/Contents/Info.plist"
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
  [[ "$actual" == "$VERSION" ]] || fail "Built marketing version $actual does not match VERSION=$VERSION"
  actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
  [[ "$actual" == "$BUILD_VERSION" ]] || fail "Built bundle version $actual does not match BUILD_VERSION=$BUILD_VERSION"
}

# Copies the Release app into a drag-to-Applications DMG at $DMG_PATH.
create_dmg() {
  run rm -rf "$DMG_STAGING" "$DMG_PATH"
  run mkdir -p "$DMG_STAGING"
  run cp -R "$(app_path Release)" "$DMG_STAGING/"
  run ln -s /Applications "$DMG_STAGING/Applications"
  run hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
}

# Builds, signs, notarizes, and staples the Release app and its DMG.
build_notarized_dmg() {
  local app
  app=$(app_path Release)

  require_newer_build_version
  xcodebuild_app Release build
  validate_built_version

  run codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$app"
  run codesign --verify --deep --strict --verbose=4 "$app"
  run rm -rf "$APP_ZIP_PATH"
  run mkdir -p "$DIST_DIR"
  run ditto -c -k --keepParent "$app" "$APP_ZIP_PATH"
  run xcrun notarytool submit "$APP_ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  run xcrun stapler staple "$app"
  run xcrun stapler validate "$app"
  run spctl --assess --type execute --verbose=4 "$app"

  create_dmg
  run codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
  run xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  run xcrun stapler staple "$DMG_PATH"
  run xcrun stapler validate "$DMG_PATH"
  run spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
  echo "Created notarized DMG at $DMG_PATH"
}

generate_appcast() {
  run rm -rf "$APPCAST_STAGING" "$APPCAST_PATH"
  run mkdir -p "$APPCAST_STAGING"
  run cp "$DMG_PATH" "$APPCAST_STAGING/"
  run "$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/ilstar/github-panel/releases/download/$RELEASE_TAG/" \
    --link "https://github.com/ilstar/github-panel/releases/tag/$RELEASE_TAG" \
    -o "$APPCAST_PATH" \
    "$APPCAST_STAGING"
  run rm -rf "$APPCAST_STAGING"
}

publish_github_release() {
  if ! dry_run && gh release view "$RELEASE_TAG" >/dev/null 2>&1; then
    echo "Uploading $DMG_PATH and $APPCAST_PATH to existing GitHub release $RELEASE_TAG"
    run gh release upload "$RELEASE_TAG" "$DMG_PATH" "$APPCAST_PATH" --clobber
  else
    echo "Creating GitHub release $RELEASE_TAG with $DMG_PATH and $APPCAST_PATH"
    # GH_RELEASE_FLAGS is intentionally word-split, e.g. "--draft --prerelease".
    # shellcheck disable=SC2086
    run gh release create "$RELEASE_TAG" "$DMG_PATH" "$APPCAST_PATH" \
      --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES" $GH_RELEASE_FLAGS
  fi
}
