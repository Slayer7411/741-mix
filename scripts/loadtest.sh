#!/bin/zsh
# Lasttest am Audio-Interface (Selbsttest-Modus: schreibt keine Einstellungen, eigener Cache im Temp-Ordner).
# Stufen Puffer 512 -> 256 -> 128 (-> 64), je Stufe 4 Decks Keylock + Sync, Link an, Delay + Hall auf FX 1/2,
# isoliertes Plugin auf FX 3, Störlast (Track-Wechsel 60 s, Suche 20 s, Hauptthread-Block 1 s alle 5 min).
# Aufruf:  scripts/loadtest.sh [--minutes 10] [--buffers 512,256,128,64] [--modes serial,parallel] [--out <Gerätename>]
#                              [--plugin <id>|none] [--mute] [--builtin] [--debug] [--no-build]
# --modes: Rechenkern je Stufe, serial (ein Audio-Thread, Standard) und/oder parallel (Decks B–D auf Worker-Threads)
# Log:     ~/Library/Application Support/MINOS-741/loadtest/latest.log (tail -f), Rohausgabe <datum>-raw.log daneben
# Ctrl-C:  Zusammenfassung bis dahin, Ausgabe aus, Ende
set -uo pipefail
cd "$(dirname "$0")/.."

MINUTES=10 BUFFERS=512,256,128 MODES=serial OUT="" PLUGIN="" MUTE="" BUILTIN="" CONFIG=release BUILD=1
while (( $# )); do
  case $1 in
    --minutes) MINUTES=$2; shift ;;
    --buffers) BUFFERS=$2; shift ;;
    --modes) MODES=$2; shift ;;
    --out) OUT=$2; shift ;;
    --plugin) PLUGIN=$2; shift ;;
    --mute) MUTE=1 ;;
    --builtin) BUILTIN=1 ;;
    --debug) CONFIG=debug ;;
    --no-build) BUILD="" ;;
    *) print -u2 "unbekannt: $1"; exit 2 ;;
  esac
  shift
done

if [[ -n $BUILD ]]; then swift build -c $CONFIG || exit 1; fi
BIN=$(swift build -c $CONFIG --show-bin-path)/minos741
[[ -x $BIN ]] || { print -u2 "fehlt: $BIN (ohne --no-build bauen)"; exit 1 }

DIR="$HOME/Library/Application Support/MINOS-741/loadtest"
mkdir -p "$DIR"
RAW="$DIR/$(date +%Y-%m-%d_%H-%M-%S)-raw.log"

export MIX741_SELFTEST=1 MIX741_BENCH=loadtest MIX741_LOADTEST_MIN=$MINUTES MIX741_BENCH_BUFFERS=$BUFFERS MIX741_BENCH_MODES=$MODES
[[ -n $OUT ]] && export MIX741_OUT=$OUT
[[ -n $PLUGIN ]] && export MIX741_BENCH_PLUGIN=$PLUGIN
[[ -n $MUTE ]] && export MIX741_LOADTEST_MUTE=1
[[ -n $BUILTIN ]] && export MIX741_NOEXT=1

: > "$RAW"
print "loadtest: $CONFIG · $MINUTES min je Stufe · Puffer $BUFFERS · Kern $MODES · Rohausgabe $RAW"
"$BIN" > "$RAW" 2>&1 &
PID=$!
trap 'kill -INT $PID 2>/dev/null' INT TERM
tail -n +1 -f "$RAW" | grep --line-buffered '^\[loadtest\]' &
TAIL=$!
RC=0
while kill -0 $PID 2>/dev/null; do wait $PID; RC=$?; done
sleep 0.5
kill $TAIL 2>/dev/null
pkill -P $$ tail 2>/dev/null
print "loadtest: Ende ($RC) · Log $DIR/latest.log"
exit $RC
