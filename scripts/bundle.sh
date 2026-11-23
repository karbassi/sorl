#!/bin/bash
# Builds Sorl with SwiftPM and assembles a signed (ad-hoc) .app bundle in build/.
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

# Sign last: the signature seals Info.plist. Ad-hoc identity ("-") is enough for a locally built app.
codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"
# Let Launch Services pick up the (possibly changed) Info.plist and URL scheme.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$OUT" >/dev/null 2>&1 || true
echo "✓ $OUT"
