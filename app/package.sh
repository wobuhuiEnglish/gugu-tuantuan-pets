#!/bin/bash
# Builds an installer (.pkg) that puts "谷谷和团团.app" into /Applications, so it shows up in Launchpad.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$APP_DIR/../GuguTuantuan-Installer.pkg}"
WORK="$APP_DIR/.build/pkg"
rm -rf "$WORK"; mkdir -p "$WORK/root" "$WORK/scripts"
ditto "$APP_DIR/谷谷和团团.app" "$WORK/root/谷谷和团团.app"
# Always install into /Applications, even if an older copy sits somewhere else.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/components.plist"
# Quit a running copy first, start the new one afterwards.
cat > "$WORK/scripts/preinstall" <<'SH'
#!/bin/bash
pkill -x CatPets || true
exit 0
SH
cat > "$WORK/scripts/postinstall" <<'SH'
#!/bin/bash
USER_NAME=$(stat -f %Su /dev/console)
[ -n "$USER_NAME" ] && [ "$USER_NAME" != root ] && sudo -u "$USER_NAME" open "/Applications/谷谷和团团.app" || true
exit 0
SH
chmod +x "$WORK/scripts/"*
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_DIR/谷谷和团团.app/Contents/Info.plist" 2>/dev/null || echo 1.0)
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --scripts "$WORK/scripts" \
  --identifier io.github.wobuhuienglish.gugu-tuantuan-pets --version "$VERSION" \
  --install-location /Applications "$WORK/component.pkg" >/dev/null
cat > "$WORK/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>谷谷和团团</title>
  <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
  <choice id="default"/>
  <choice id="app" visible="false"><pkg-ref id="io.github.wobuhuienglish.gugu-tuantuan-pets"/></choice>
  <pkg-ref id="io.github.wobuhuienglish.gugu-tuantuan-pets" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$OUT" >/dev/null
echo "installer: $OUT"
