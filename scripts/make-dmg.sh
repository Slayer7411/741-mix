#!/bin/zsh
# Release-DMG: universelle App + Verknüpfung zu /Applications -> build/MINOS-741-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
UNIVERSAL=1 scripts/make-app.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MINOS-741.app/Contents/Info.plist)
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto build/MINOS-741.app "$STAGE/MINOS-741.app"
ln -s /Applications "$STAGE/Applications"
DMG=build/MINOS-741-$VERSION.dmg
rm -f "$DMG"
hdiutil create -volname "MINOS-741 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "dmg: $DMG"
