#!/bin/zsh
# Veröffentlicht einen Build als GitHub-Release (Update-Quelle der App). Nie automatisch: ohne --yes passiert nichts,
# --dry-run zeigt nur die Befehle (baut nichts, lädt nichts hoch).
#
#   scripts/release.sh <version> --name <NAME> --dry-run   versioniertes Release v<version>, nur anzeigen
#   scripts/release.sh <version> --name <NAME> --yes       versioniertes Release (Kanal „Stabile Versionen“)
#   scripts/release.sh --rolling --dry-run                 rollendes Release latest-build, nur anzeigen
#   scripts/release.sh --rolling --yes                     rollendes Release latest-build (Kanal „Neuester Build“)
#
# Versioniert: Tag v<version> muss auf HEAD liegen und auf GitHub sein; Titel „◆ v<version> · <NAME>“ (wie bisher).
# Rollend: Tag latest-build wird auf HEAD verschoben, Release als Vorabversion (prerelease), Assets werden ersetzt.
# Beide Modi: scripts/make-dmg.sh (universal), latest.json mit Adresse der DMG und SHA-256, Ausgabe in build/release/.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="Slayer7411/MINOS-741"
VERSION="" NAME="" ROLLING="" YES="" DRY=""
while (( $# > 0 )); do
  case $1 in
    --rolling) ROLLING=1 ;;
    --name) NAME=${2:?"--name braucht einen Namen (z. B. UNIVERSAL)"}; shift ;;
    --yes) YES=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) echo "unbekannte Option: $1" >&2; exit 2 ;;
    *) [[ -z $VERSION ]] || { echo "nur eine Version angeben" >&2; exit 2; }; VERSION=$1 ;;
  esac
  shift
done

if [[ -z $DRY && -z $YES ]]; then
  echo "Nichts veröffentlicht: --yes (oder --dry-run zum Ansehen) angeben." >&2
  exit 2
fi
if [[ -n $ROLLING && -n $VERSION ]]; then echo "--rolling und Version schließen sich aus" >&2; exit 2; fi
if [[ -z $ROLLING ]]; then
  [[ -n $VERSION ]] || { echo "Version fehlt: release.sh <version> --name <NAME>" >&2; exit 2; }
  [[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Version als X.Y.Z angeben: $VERSION" >&2; exit 2; }
  [[ -n $NAME && $NAME =~ ^[A-Z0-9][A-Z0-9\ -]*$ ]] || { echo "--name in Großbuchstaben angeben (z. B. UNIVERSAL)" >&2; exit 2; }
fi

# Ausführen oder (Trockenlauf) nur zeigen
run() {
  print -r -- "+ ${(q-)@}"
  [[ -n $DRY ]] || "$@"
}

# Codename der Hauptversion (scripts/codename.sh; wie CONTRIBUTING.md): rollend = Version des letzten Tags
if [[ -n $ROLLING ]]; then
  TAG=latest-build
  ASSET=MINOS-741.dmg
  CODE_VERSION=$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null | sed 's/^v//' || true)
  CODENAME=$(scripts/codename.sh "$CODE_VERSION")
  TITLE="◆ LATEST BUILD · $CODENAME"
else
  TAG=v$VERSION
  ASSET=MINOS-741-$VERSION.dmg
  CODENAME=$(scripts/codename.sh "$VERSION")
  TITLE="◆ v$VERSION · $CODENAME · $NAME"
fi
URL="https://github.com/$REPO/releases/download/$TAG/$ASSET"
OUT=build/release

# Vorbedingungen (lokal)
HEAD_SHA=$(git rev-parse HEAD)
if [[ -n $(git status --porcelain) ]]; then
  if [[ -n $DRY ]]; then echo "hinweis: Arbeitskopie nicht sauber (echter Lauf bricht ab)"; else
    echo "Arbeitskopie nicht sauber: committen oder stashen (kein stash in main, siehe Notizen)" >&2; exit 1; fi
fi
if [[ -z $ROLLING ]]; then
  if [[ "$(git describe --tags --match 'v*' --abbrev=0 2>/dev/null || true)" != "$TAG" ]]; then
    echo "Tag $TAG ist nicht der neueste Versions-Tag (git describe): erst taggen, dann veröffentlichen" >&2
    [[ -n $DRY ]] || exit 1
  fi
  if [[ "$(git rev-parse "$TAG^{commit}" 2>/dev/null || echo none)" != "$HEAD_SHA" ]]; then
    echo "Tag $TAG zeigt nicht auf HEAD ($HEAD_SHA)" >&2
    [[ -n $DRY ]] || exit 1
  fi
fi
if ! git branch -r --contains "$HEAD_SHA" 2>/dev/null | grep -q "origin/"; then
  echo "hinweis: HEAD liegt noch nicht auf origin (git push zuerst)"
  [[ -n $DRY ]] || exit 1
fi

echo "Modus: $([[ -n $ROLLING ]] && echo rollend || echo versioniert) · Tag $TAG · Titel „$TITLE“ · Asset $ASSET"
echo "Adresse: $URL"

# Bauen (universal) und Manifest
run scripts/make-dmg.sh
if [[ -z $DRY ]]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/MINOS-741.app/Contents/Info.plist)
  BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" build/MINOS-741.app/Contents/Info.plist)
  CODE=$(/usr/libexec/PlistBuddy -c "Print MINOSCodename" build/MINOS-741.app/Contents/Info.plist 2>/dev/null || echo "$CODENAME")
  DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$OUT"
  cp "build/MINOS-741-$VER.dmg" "$OUT/$ASSET"
  SHA=$(shasum -a 256 "$OUT/$ASSET" | awk '{print $1}')
  SIZE=$(stat -f %z "$OUT/$ASSET")
  python3 -I - "$OUT/latest.json" "$VER" "$BUILD" "$ASSET" "$SHA" "$SIZE" "$DATE" "$URL" "$CODE" <<'PY'
import json, sys
path, ver, build, asset, sha, size, date, url, codename = sys.argv[1:]
with open(path + ".tmp", "w", encoding="utf-8") as f:
    json.dump({"version": ver, "build": build, "file": asset, "sha256": sha, "size": int(size), "date": date,
               "minSystem": "15.0", "url": url, "codename": codename}, f)
import os; os.replace(path + ".tmp", path)
PY
  echo "manifest: $OUT/latest.json ($BUILD, $SHA)"
else
  echo "+ (Manifest mit Größe, SHA-256, Datum und Adresse wird nach dem Bauen geschrieben: $OUT/$ASSET, $OUT/latest.json)"
fi

# Veröffentlichen
if [[ -n $ROLLING ]]; then
  echo "+ Tag verschieben und hochladen:"
  run git tag -f "$TAG"
  run git push -f origin "$TAG"
  if [[ -n $DRY ]]; then
    echo "+ gh release view $TAG || gh release create $TAG --prerelease --verify-tag --title '$TITLE' --notes '…'"
  else
    gh release view "$TAG" >/dev/null 2>&1 || run gh release create "$TAG" --prerelease --verify-tag --title "$TITLE" \
      --notes "Rolling build of the current main branch. Updated on every publish."
  fi
  run gh release edit "$TAG" --prerelease --title "$TITLE"
  run gh release upload "$TAG" "$OUT/$ASSET" "$OUT/latest.json" --clobber
else
  run gh release create "$TAG" "$OUT/$ASSET" "$OUT/latest.json" --verify-tag --title "$TITLE" \
    --notes "MINOS-741 $VERSION ($NAME)."
fi
echo "fertig: $([[ -n $DRY ]] && echo 'Trockenlauf, nichts veröffentlicht' || echo "$URL")"
