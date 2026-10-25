#!/bin/bash
# Builds "谷谷和团团.app" from Sources/main.swift, manifest.json and the cut-out frames.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PETS="$(cd "$APP_DIR/.." && pwd)"
APP="$APP_DIR/谷谷和团团.app"
BUILD="$APP_DIR/.build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/cats" "$BUILD"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

# Some upgraded Command Line Tools keep a stale module map next to the new one;
# hide only that duplicate through a virtual filesystem overlay (same fix as the Trump pet).
SWIFT_INCLUDE="$(dirname "$(xcrun --find swiftc)")/../include/swift"
OVERLAY=()
if [ -f "$SWIFT_INCLUDE/module.modulemap" ] && [ -f "$SWIFT_INCLUDE/bridging.modulemap" ]; then
  SWIFT_INCLUDE="$(cd "$SWIFT_INCLUDE" && pwd)"
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/overlay.yaml" <<YAML
version: 0
roots:
  - type: file
    name: "$SWIFT_INCLUDE/module.modulemap"
    external-contents: "$BUILD/empty.modulemap"
YAML
  OVERLAY=(-vfsoverlay "$BUILD/overlay.yaml")
fi

for ARCH in arm64 x86_64; do
  xcrun swiftc -O "$APP_DIR"/Sources/*.swift -o "$BUILD/CatPets-$ARCH" \
    -sdk "$SDK" -target "$ARCH-apple-macosx13.0" -module-cache-path "$BUILD/mc-$ARCH" \
    "${OVERLAY[@]}" -framework AppKit -framework ImageIO -framework Carbon -framework IOKit
done
lipo -create "$BUILD/CatPets-arm64" "$BUILD/CatPets-x86_64" -output "$APP/Contents/MacOS/CatPets"

# Copy each action folder named in the manifest: "<cat>/<action>" <- frames/<source>.
RES="$APP/Contents/Resources/cats"
cp "$APP_DIR/manifest.json" "$RES/"
while read -r dest src; do
  [ -z "$dest" ] && continue
  mkdir -p "$RES/$dest"
  cp "$PETS/frames/$src"/f.json "$RES/$dest/"
  for f in "$PETS/frames/$src"/f-*.png; do
    # Keep the bundle light: frames are drawn at most ~2x of 150pt.
    sips -Z 420 "$f" --out "$RES/$dest/$(basename "$f")" >/dev/null
  done
done < "$APP_DIR/frames.txt"

# App icon: every size macOS wants, made from the one 1024px drawing.
ICONSET="$BUILD/AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
  sips -z $S $S "$APP_DIR/icon/AppIcon-1024.png" --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
  sips -z $((S*2)) $((S*2)) "$APP_DIR/icon/AppIcon-1024.png" --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.wobuhuienglish.gugu-tuantuan-pets</string>
<key>CFBundleName</key><string>谷谷和团团</string>
<key>CFBundleDisplayName</key><string>谷谷和团团</string>
<key>CFBundleExecutable</key><string>CatPets</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
