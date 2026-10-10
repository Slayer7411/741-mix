#!/bin/zsh
# Baut MINOS-741.app (Release), signiert ad hoc und installiert nach /Applications.
# Aufruf: scripts/make-app.sh            -> bauen + installieren
#         scripts/make-app.sh --no-install
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="0.$(git rev-list --count HEAD 2>/dev/null || echo 0)"
BUILD=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
APP=build/MINOS-741.app

swift build -c release
BIN=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Resources"
cp "$BIN/minos741" "$APP/Contents/MacOS/MINOS-741"
cp -R Sources/MixApp/Resources/. "$APP/Contents/Resources/Resources/"
cp -R Localization/. "$APP/Contents/Resources/"

# Icon: AppIcon.png -> AppIcon.icns
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Sources/MixApp/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Sources/MixApp/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MINOS-741</string>
  <key>CFBundleDisplayName</key><string>MINOS-741</string>
  <key>CFBundleIdentifier</key><string>com.github.slayer7411.minos741</string>
  <key>CFBundleDevelopmentRegion</key><string>de</string>
  <key>NSLocalNetworkUsageDescription</key><string>Ableton Link: MINOS-741 syncs tempo and beat with Ableton Live and other Link apps on this network.</string>
  <key>CFBundleLocalizations</key><array><string>de</string><string>en</string></array>
  <key>CFBundleExecutable</key><string>MINOS-741</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "gebaut: $APP ($VERSION, $BUILD)"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x MINOS-741 2>/dev/null || true
  pkill -x 741mix 2>/dev/null || true
  rm -rf /Applications/741-mix.app   # alter Name
  rm -rf /Applications/MINOS-741.app
  ditto "$APP" /Applications/MINOS-741.app
  echo "installiert: /Applications/MINOS-741.app"
fi
