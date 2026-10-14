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
  # ein Lauf, Ausgabe gesichert: rote Tests stehen im Log, Ergebnis aus dem Exit-Code (zwei Läufe verdoppelten nur das Flattern)
  tlog=$(mktemp)
  trc=0; swift test --no-parallel >"$tlog" 2>&1 || trc=$?
  grep -E "✘|Test run with" "$tlog" || true
  [ $trc = 0 ] || { grep -E "error:|Expectation failed|recorded an issue" "$tlog" | head -20; rm -f "$tlog"; echo "FEHLER: Unit-Tests rot"; exit 1; }
  rm -f "$tlog"
fi
echo "== selftest"
# Ausgabe gesichert: bei Rot die letzten Fehlerzeilen zeigen (unter Last flattert sonst nur „FEHLER: Selbsttest“ ohne Grund)
slog=$(mktemp)
MIX741_SELFTEST=1 MIX741_NOEXT=1 .build/debug/minos741 >"$slog" 2>&1 || true
grep -E "SELFTEST|FAIL|Fehler" "$slog" | tail -3 | grep -q "SELFTEST OK" || { grep -n -B3 -E "FAIL|FALSCH|SELFTEST" "$slog" | tail -20; echo "Last: $(uptime | sed 's/.*load/load/')"; rm -f "$slog"; echo "FEHLER: Selbsttest"; exit 1; }
rm -f "$slog"
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
