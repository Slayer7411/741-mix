#!/bin/zsh
# UI-Selbsttest: echtes Hauptfenster offscreen, synthetische Maus- und Tastaturereignisse, stumm auf einem eingebauten
# Gerät, schreibt keine Einstellungen. Ohne Collection (CI) mit erzeugter Fixture-Collection im Temp-Ordner.
# Aufruf:  scripts/uitest.sh [--fixture] [--only <fall,…>] [--limit <s>] [--no-build]
# Ende:    `UITEST OK` (0), `UITEST ÜBERSPRUNGEN` (0, kein Audiogerät / keine Tracks), sonst erster Fehler (1)
set -uo pipefail
cd "$(dirname "$0")/.."

FIXTURE="" ONLY="" LIMIT=120 BUILD=1
while (( $# )); do
  case $1 in
    --fixture) FIXTURE=1 ;;
    --only) ONLY=$2; shift ;;
    --limit) LIMIT=$2; shift ;;
    --no-build) BUILD="" ;;
    *) print -u2 "unbekannt: $1"; exit 2 ;;
  esac
  shift
done

if [[ -n $BUILD ]]; then swift build || exit 1; fi
BIN=$(swift build --show-bin-path)/minos741
[[ -x $BIN ]] || { print -u2 "fehlt: $BIN (ohne --no-build bauen)"; exit 1 }

export MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_UITEST=1
[[ -n $FIXTURE ]] && export MIX741_UITEST_FIXTURE=1
[[ -n $ONLY ]] && export MIX741_UITEST_ONLY=$ONLY

# Wächter: hängt der Test (z. B. ein modaler Dialog), nach LIMIT s beenden
"$BIN" &
PID=$!
{ sleep $LIMIT; kill -9 $PID 2>/dev/null && print -u2 "uitest: nach $LIMIT s abgebrochen" } &
WATCH=$!
wait $PID
RC=$?
kill $WATCH 2>/dev/null
exit $RC
