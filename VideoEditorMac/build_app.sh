#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
WORKSPACE="${ROOT:h}"
SOURCE="$ROOT/Sources/main.swift"
APP="$WORKSPACE/Video Editor.app"
STAGING="$(mktemp -d -t video-editor-app.XXXXXX)"
STAGED_APP="$STAGING/Video Editor.app"
SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"

cleanup() {
  rm -rf "$STAGING"
}
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

[[ -d "$SDK" ]] || SDK="$(xcrun --show-sdk-path)"

# The small launch guard runs on macOS 11/12 and explains that the editor needs 13+.
MACOSX_DEPLOYMENT_TARGET=11.0 xcrun swiftc \
  -target "arm64-apple-macos11.0" \
  -swift-version 5 \
  -O \
  -sdk "$SDK" \
  -module-cache-path "$STAGING/ModuleCache" \
  -framework AppKit \
  -framework AVFoundation \
  -framework AVKit \
  -framework UniformTypeIdentifiers \
  "$SOURCE" \
  -o "$STAGED_APP/Contents/MacOS/VideoEditor"

cp "$ROOT/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$ROOT/Resources/video_engine" "$STAGED_APP/Contents/Resources/video_engine"

ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon-master.png" \
    --out "$ICONSET/$name" >/dev/null
done
ICON_ENTRIES=(
  "icp4 icon_16x16.png"
  "ic11 icon_16x16@2x.png"
  "icp5 icon_32x32.png"
  "ic12 icon_32x32@2x.png"
  "ic07 icon_128x128.png"
  "ic13 icon_128x128@2x.png"
  "ic08 icon_256x256.png"
  "ic14 icon_256x256@2x.png"
  "ic09 icon_512x512.png"
  "ic10 icon_512x512@2x.png"
)
ICNS_SIZE=8
for entry in "${ICON_ENTRIES[@]}"; do
  name="${entry#* }"
  bytes="$(stat -f '%z' "$ICONSET/$name")"
  ICNS_SIZE=$((ICNS_SIZE + bytes + 8))
done
ICNS_FILE="$STAGED_APP/Contents/Resources/AppIcon.icns"
perl -e 'print "icns", pack("N", $ARGV[0])' "$ICNS_SIZE" > "$ICNS_FILE"
for entry in "${ICON_ENTRIES[@]}"; do
  type="${entry%% *}"
  name="${entry#* }"
  bytes="$(stat -f '%z' "$ICONSET/$name")"
  perl -e 'print $ARGV[0], pack("N", $ARGV[1])' "$type" "$((bytes + 8))" >> "$ICNS_FILE"
  cat "$ICONSET/$name" >> "$ICNS_FILE"
done

chmod 755 "$STAGED_APP/Contents/MacOS/VideoEditor"
chmod 755 "$STAGED_APP/Contents/Resources/video_engine"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

codesign --force --deep --sign - "$STAGED_APP" >/dev/null

rm -rf "$APP"
mv "$STAGED_APP" "$APP"

echo "$APP"
