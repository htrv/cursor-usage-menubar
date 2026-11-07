#!/usr/bin/env bash
# Собирает build/Cursor Usage.app из release-бинарника (для автозапуска / ~/Applications).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Cursor Usage"
BUNDLE_ID="${BUNDLE_ID:-com.github.cursor-usage-menubar}"
OUT="$ROOT/build/$APP_NAME.app"

swift build -c release
BIN="$ROOT/.build/release/CursorUsageMenubar"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/CursorUsage"

cat >"$OUT/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>CursorUsage</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$OUT" >/dev/null 2>&1 || true
echo "OK: $OUT"
echo "Установить: cp -R \"$OUT\" ~/Applications/ && open ~/Applications/\"$APP_NAME.app\""
