#!/bin/sh
# Pflichtprüfung vor jedem Merge nach main und vor jeder Installation:
# Debug-Build, Unit-Tests, Selbsttest (stumm, ohne externe Geräte), Tabellen-Prüfungen, UI-Test (falls vorhanden).
# Aufruf: scripts/check.sh [--quick]   (--quick: ohne Unit-Tests)
set -e
cd "$(dirname "$0")/.."
quick=0; [ "$1" = "--quick" ] && quick=1
t0=$(date +%s)
echo "== build"
swift build 2>&1 | grep -E "error:|warning:.*Sources/|Build complete" | grep -v "Swift 6 language mode" || true
swift build >/dev/null 2>&1
if [ $quick = 0 ]; then
  echo "== swift test"
  swift test 2>&1 | grep -E "✘|Test run with" || true
  swift test >/dev/null 2>&1 || { echo "FEHLER: Unit-Tests rot"; exit 1; }
fi
echo "== selftest"
MIX741_SELFTEST=1 MIX741_NOEXT=1 .build/debug/minos741 2>&1 | grep -E "SELFTEST|FAIL|Fehler" | tail -3 | grep -q "SELFTEST OK" || { echo "FEHLER: Selbsttest"; exit 1; }
echo "== table checks"
out=$(mktemp -d)
MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_SHOT="table:$out/table.png" MIX741_SHOT_CHECKS=1 .build/debug/minos741 2>&1 | grep -iE "prüfungen|FAIL" | tail -2 | grep -qi "prüfungen OK" || { echo "FEHLER: Tabellen-Prüfungen"; exit 1; }
echo "== deck / window shots"
MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_SHOT="deck:$out/deck.png" .build/debug/minos741 >/dev/null 2>&1 || { echo "FEHLER: Deck-Shot"; exit 1; }
MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_SHOT="window:$out/window.png" .build/debug/minos741 >/dev/null 2>&1 || { echo "FEHLER: Window-Shot"; exit 1; }
if grep -q "MIX741_UITEST" Sources/MixApp/*.swift 2>/dev/null; then
  echo "== ui test"
  MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_UITEST=1 .build/debug/minos741 2>&1 | grep -E "UITEST|FAIL" | tail -2 | grep -q "UITEST OK" || { echo "FEHLER: UI-Test"; exit 1; }
fi
rm -rf "$out"
echo "CHECK OK ($(( $(date +%s) - t0 )) s)"
