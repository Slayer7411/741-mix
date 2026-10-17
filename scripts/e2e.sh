#!/bin/bash
# Ende-zu-Ende-Tests: echte App (Debug-Build), eigene Ordner und Suite je Instanz, Szenarien in Tests/E2E/scenarios.
# Aufruf:  scripts/e2e.sh [--no-build] [szenario …]      (ohne Namen: alle; --list zeigt sie)
# Umgebung: E2E_OUT=<ordner> (Ausgabe bei Fehlern, Standard: $TMPDIR/minos741-e2e), E2E_KEEP=1 (Ordner behalten)
# Ende: Tabelle PASS/FAIL, Exit 0 = alle bestanden. Beschreibung: Tests/E2E/README.md
set -uo pipefail
cd "$(dirname "$0")/.."

BUILD=1
ARGS=()
for a in "$@"; do
  case $a in
    --no-build) BUILD="" ;;
    *) ARGS+=("$a") ;;
  esac
done

if [[ "${ARGS[0]:-}" == "--list" ]]; then exec python3 -I Tests/E2E/run.py --list; fi
if [[ -n $BUILD ]]; then swift build || exit 1; fi
BIN=$(swift build --show-bin-path)/minos741
[[ -x $BIN ]] || { echo "fehlt: $BIN (ohne --no-build bauen)" >&2; exit 1; }
[[ -x $(dirname "$BIN")/minos-files ]] || { echo "fehlt: minos-files neben $BIN" >&2; exit 1; }

E2E_BIN="$BIN" python3 -I Tests/E2E/run.py "${ARGS[@]+"${ARGS[@]}"}"
