#!/usr/bin/env bash
# Packs the brand icon (docs/brand/sorl-icon-1024.png) into an .icns.
# Usage: scripts/make-icon.sh Resources/AppIcon.icns
set -euo pipefail

SOURCE="docs/brand/sorl-icon-1024.png"
OUTPUT="${1:?usage: make-icon.sh <output.icns>}"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
rm -rf "$(dirname "$ICONSET")"
echo "✓ $OUTPUT"
