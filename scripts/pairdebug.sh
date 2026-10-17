#!/bin/bash
# Fernabfrage des anderen Macs (Zwei-Mac-Modus, Sources/MixApp/PairDebug.swift).
# Aufruf: scripts/pairdebug.sh <befehl> [args]
#   ping | snapshot | status | prefs-get | prefs-set '<json>' | defaults-get <schluessel> | defaults-set '<json>'
# Anfrage -> Ordnerpost outbox/, Antwort aus inbox/ (nach token), 10 s Frist. Exit 0 = ok, 1 = Absage oder keine Antwort.
set -u

if [ $# -lt 1 ]; then
  echo "aufruf: pairdebug.sh <befehl> [args]" >&2
  exit 2
fi
command_name="$1"
shift
args="$*"

dir="$HOME/Library/Application Support/MINOS-741/pair-debug"
outbox="$dir/outbox"
inbox="$dir/inbox"
mkdir -p "$outbox" "$inbox" || exit 1

token="$(date +%s)-$$-$RANDOM"
tmp="$outbox/.$token.tmp"
PD_COMMAND="$command_name" PD_ARGS="$args" PD_TOKEN="$token" python3 -c '
import json, os
print(json.dumps({"command": os.environ["PD_COMMAND"], "args": os.environ["PD_ARGS"], "token": os.environ["PD_TOKEN"]}))
' > "$tmp" || { rm -f "$tmp"; exit 1; }
mv "$tmp" "$outbox/$token.json" || exit 1

# Antwort mit diesem Token suchen; 0 = ok, 2 = Absage, 3 = fremde Datei
check='
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as f:
    d = json.load(f)
if d.get("token") != os.environ["PD_TOKEN"]:
    sys.exit(3)
print(json.dumps(d, indent=2, ensure_ascii=False))
sys.exit(0 if d.get("ok") else 2)
'

deadline=$((SECONDS + 10))
while [ "$SECONDS" -lt "$deadline" ]; do
  for f in "$inbox"/*.json; do
    [ -e "$f" ] || continue
    out="$(PD_TOKEN="$token" python3 -c "$check" "$f" 2>/dev/null)"
    rc=$?
    case $rc in
      0) echo "$out"; exit 0 ;;
      2) echo "$out"; exit 1 ;;
    esac
  done
  sleep 0.2
done

# keine Antwort: Anfrage wegnehmen, damit sie nicht später noch ausgeführt wird
rm -f "$outbox/$token.json"
echo "keine Antwort innerhalb 10 s (läuft MINOS auf dem anderen Mac, Zwei-Mac-Modus an, Fernzugriff erlaubt?)" >&2
exit 1
