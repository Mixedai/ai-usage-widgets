#!/bin/bash
# Claude Usage Widget — derle, .app olarak paketle, ~/Applications'a kur ve başlat.
# Kullanım:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ClaudeUsageWidget"
BUNDLE_ID="com.mixedaitape.ClaudeUsageWidget"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
DEST="$HOME/Applications"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "✗ swiftc bulunamadı. Önce şunu çalıştır:  xcode-select --install"
  exit 1
fi

echo "→ Derleniyor…"
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library \
  -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/ClaudeUsageWidget.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Claude Usage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "→ Kuruluyor: $DEST/$APP_NAME.app"
mkdir -p "$DEST"
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/$APP_NAME.app"
cp -R "$APP" "$DEST/"

# Not: Anthropic'in kullanım endpoint'i sıkı bir istek kotası uyguluyor (Claude Code
# oturumlarıyla ortak). Kotayı boşa harcamamak için burada ayrıca bağlantı testi yapılmıyor;
# teşhis için:  "$DEST/$APP_NAME.app/Contents/MacOS/$APP_NAME" --once

echo "→ Başlatılıyor…"
open "$DEST/$APP_NAME.app"
echo "✓ Hazır. Sürükleyerek taşı, sağ tıkla menüyü aç."
