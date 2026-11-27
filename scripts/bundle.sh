#!/bin/bash
# Builds Sorl with SwiftPM and assembles a signed .app bundle in build/ (ad-hoc, or dev/Developer ID signed when SORL_SIGN_IDENTITY and SORL_PROFILE are set).
# No Xcode required: works with the Command Line Tools alone.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Sorl"
BUNDLE_ID="com.karbassi.sorl"
VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
CONFIG="${CONFIG:-release}"
OUT="build/$APP.app"
# ARCHS="arm64 x86_64" builds a universal binary (releases do); unset builds for this Mac only.
ARCH_ARGS=""
for arch in ${ARCHS:-}; do ARCH_ARGS="$ARCH_ARGS --arch $arch"; done

# Signing mode, checked before building. Neither SORL_SIGN_IDENTITY nor SORL_PROFILE: ad-hoc, no entitlements.
# Both: sign with that identity, embed the profile and the iCloud entitlements (hardened runtime).
DEV_SIGN=""
if [ -n "${SORL_SIGN_IDENTITY:-}" ] || [ -n "${SORL_PROFILE:-}" ]; then
  [ -n "${SORL_SIGN_IDENTITY:-}" ] && [ -n "${SORL_PROFILE:-}" ] \
    || { echo "set both SORL_SIGN_IDENTITY and SORL_PROFILE, or neither" >&2; exit 1; }
  [ -f "$SORL_PROFILE" ] || { echo "SORL_PROFILE does not point to a file" >&2; exit 1; }
  [ -n "${SORL_TEAM_ID:-}" ] || { echo "SORL_TEAM_ID is required when signing" >&2; exit 1; }
  case "${SORL_CK_ENV:-}" in
    Development) APS_ENV="development" ;;
    Production) APS_ENV="production" ;;
    *) echo "SORL_CK_ENV must be Development or Production" >&2; exit 1 ;;
  esac
  DEV_SIGN=1
fi

echo "▸ swift build -c $CONFIG --product $APP$ARCH_ARGS"
# Build only the app product: the SorlSelfTest target needs -enable-testing, which is debug-only.
swift build -c "$CONFIG" --product "$APP" $ARCH_ARGS 2>&1 | grep -vE '^\s*$' | tail -n 3
BIN="$(swift build -c "$CONFIG" --product "$APP" $ARCH_ARGS --show-bin-path)/$APP"
[ -x "$BIN" ] || { echo "binary not found at $BIN" >&2; exit 1; }

echo "▸ assembling $OUT (v$VERSION build $BUILD_NUMBER)"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
# Keep Spotlight from indexing this throwaway build copy as a second "Sorl" app
# (the real install lives in /Applications). Harmless marker file Spotlight honours.
touch build/.metadata_never_index
cp "$BIN" "$OUT/Contents/MacOS/$APP"
# Sparkle (in-app updates) lives in Contents/Frameworks; SwiftPM only adds @loader_path to the rpaths.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/$APP"
# The app deploys to macOS 15, and some SwiftPM builds then record 15.0 as the linked SDK too. AppKit keys the
# Liquid Glass control styles on the linked SDK, so a 15.0 stamp would give the old look on macOS 26.
# Record the SDK the build actually compiled against.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
vtool -set-build-version macos "$MIN_OS" "$SDK_VERSION" -replace -output "$OUT/Contents/MacOS/$APP" "$OUT/Contents/MacOS/$APP"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$OUT/Contents/Info.plist"
printf 'APPL????' > "$OUT/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"
fi
# Menu bar glyphs (template SVGs from docs/brand), loaded by StatusItemController.
cp -R Resources/MenuBar "$OUT/Contents/Resources/MenuBar"
# SwiftPM resource bundles (KeyboardShortcuts' localized strings): Bundle.module looks in Contents/Resources.
for bundle in "$(dirname "$BIN")"/*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$OUT/Contents/Resources/"
done
mkdir -p "$OUT/Contents/Frameworks"
SPARKLE="$OUT/Contents/Frameworks/Sparkle.framework"
ditto "$(dirname "$BIN")/Sparkle.framework" "$SPARKLE"
# The XPC services are only for sandboxed apps, and Sorl isn't sandboxed (it runs yt-dlp).
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

# Signs Sparkle's helpers inside-out, then the framework, with the same identity as the app. Sparkle ships signed
# by its own team, which the hardened runtime's library validation would refuse to load.
sign_sparkle() {
  for item in "$SPARKLE/Versions/B/Autoupdate" "$SPARKLE/Versions/B/Updater.app" "$SPARKLE"; do
    codesign --force "$@" "$item"
  done
}

# Sign last: the signature seals Info.plist.
if [ -z "$DEV_SIGN" ]; then
  # Ad-hoc identity ("-") is enough for a locally built app.
  sign_sparkle --sign -
  codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"
else
  echo "▸ signing (CloudKit $SORL_CK_ENV)"
  cp "$SORL_PROFILE" "$OUT/Contents/embedded.provisionprofile"
  sed -e "s/__TEAM_ID__/$SORL_TEAM_ID/g" -e "s/__CK_ENV__/$SORL_CK_ENV/g" -e "s/__APS_ENV__/$APS_ENV/g" \
    Resources/Sorl.entitlements > build/Sorl.entitlements
  sign_sparkle --options runtime --timestamp --sign "$SORL_SIGN_IDENTITY" ${SORL_KEYCHAIN:+--keychain "$SORL_KEYCHAIN"}
  # No --deep: Sparkle is signed above, and KeyboardShortcuts' resource bundle holds no code.
  codesign --force --options runtime --timestamp --entitlements build/Sorl.entitlements \
    --sign "$SORL_SIGN_IDENTITY" ${SORL_KEYCHAIN:+--keychain "$SORL_KEYCHAIN"} "$OUT"
  codesign --verify --strict --verbose=2 "$OUT"
fi
# Let Launch Services pick up the (possibly changed) Info.plist and URL scheme.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$OUT" >/dev/null 2>&1 || true
echo "✓ $OUT"
