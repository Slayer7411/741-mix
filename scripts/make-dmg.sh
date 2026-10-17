#!/bin/zsh
# Release-DMG: universelle App + Verknüpfung zu /Applications -> build/MINOS-741-<version>.dmg
# Aufruf: scripts/make-dmg.sh [--publish <ordner>]
#   --publish: zusätzlich in <ordner> kopieren (MINOS-741-<version>-<build>.dmg, erst als .part, dann umbenannt),
#              <ordner>/latest.json atomar schreiben, nur die 3 neuesten DMGs behalten (Sortierung: Datum der Datei).
#              Die App sucht dort nach Updates (Einstellungen -> ANZEIGE -> Updates).
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=""
while (( $# > 0 )); do
  case $1 in
    --publish) PUBLISH=${2:?"--publish braucht einen Ordner"}; shift 2 ;;
    *) echo "unbekannte Option: $1" >&2; exit 2 ;;
  esac
done

UNIVERSAL=1 scripts/make-app.sh --no-install
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MINOS-741.app/Contents/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MINOS-741.app/Contents/Info.plist)
STAGE=build/dmg
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto build/MINOS-741.app "$STAGE/MINOS-741.app"
ln -s /Applications "$STAGE/Applications"
DMG=build/MINOS-741-$VERSION.dmg
rm -f "$DMG"
hdiutil create -volname "MINOS-741 $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "dmg: $DMG"

if [[ -n "$PUBLISH" ]]; then
  mkdir -p "$PUBLISH"
  NAME="MINOS-741-$VERSION-$BUILD.dmg"
  DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
  SIZE=$(stat -f %z "$DMG")
  MINSYS=$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" build/MINOS-741.app/Contents/Info.plist)
  # erst unter .part kopieren, dann umbenennen: die App sieht nie eine halbe Datei
  cp "$DMG" "$PUBLISH/$NAME.part"
  mv -f "$PUBLISH/$NAME.part" "$PUBLISH/$NAME"
  # Manifest atomar: temporäre Datei, dann umbenennen
  cat > "$PUBLISH/latest.json.tmp" <<JSON
{"version": "$VERSION", "build": "$BUILD", "file": "$NAME", "sha256": "$SHA", "size": $SIZE, "date": "$DATE", "minSystem": "$MINSYS"}
JSON
  mv -f "$PUBLISH/latest.json.tmp" "$PUBLISH/latest.json"
  # nur die 3 neuesten DMGs behalten (Datum der Datei); das im Manifest genannte bleibt immer
  KEEP=$(ls -t "$PUBLISH"/MINOS-741-*.dmg 2>/dev/null | head -n 3)
  for f in "$PUBLISH"/MINOS-741-*.dmg(N); do
    [[ "$f" == "$PUBLISH/$NAME" ]] && continue
    grep -qxF "$f" <<<"$KEEP" && continue
    rm -f "$f"
  done
  echo "veröffentlicht: $PUBLISH/$NAME ($BUILD, $DATE)"
fi
