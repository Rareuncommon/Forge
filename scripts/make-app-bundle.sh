#!/usr/bin/env bash
# Wrap the SwiftPM-built ForgeApp executable into Forge.app with the OCCT dylibs embedded.
# macOS only. STATUS: written in the M0 Linux session and not yet run — verify on macOS 27.
#
# Usage: scripts/make-app-bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OCCT_PREFIX="${FORGE_OCCT_PREFIX:-$ROOT/Vendor/occt/darwin-arm64}"
OUT="$ROOT/build/Forge.app"

swift build -c "$CONFIG" --product ForgeApp --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --product ForgeApp --package-path "$ROOT" --show-bin-path)/ForgeApp"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Frameworks" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/Forge"

# Embed OCCT (LGPL: shipped as separate, replaceable dylibs — docs/adr/0005).
for lib in "$OCCT_PREFIX"/lib/libTK*.dylib; do
  cp -a "$lib" "$OUT/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$OUT/Contents/MacOS/Forge" || true
mkdir -p "$OUT/Contents/Resources/Licenses"
cp "$ROOT/docs/LICENSES.md" "$OUT/Contents/Resources/Licenses/"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Forge</string>
  <key>CFBundleDisplayName</key><string>Forge</string>
  <key>CFBundleIdentifier</key><string>app.forge.Forge</string>
  <key>CFBundleExecutable</key><string>Forge</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$OUT"
echo "Built $OUT"
