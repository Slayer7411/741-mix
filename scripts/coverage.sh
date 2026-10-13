#!/bin/sh
# Zeilenabdeckung je Target: Unit-Tests plus Selbsttest (beide instrumentiert), Ausgabe als Tabelle.
# Aufruf: scripts/coverage.sh   (Debug-Build, dauert ein paar Minuten)
set -e
cd "$(dirname "$0")/.."
out=${TMPDIR:-/tmp}/minos-coverage; rm -rf "$out"; mkdir -p "$out"
echo "== swift test (instrumentiert)"
swift test --enable-code-coverage >/dev/null 2>&1 || echo "(Unit-Tests mit Fehlern, Abdeckung trotzdem gemessen)"
prod=$(ls -d .build/out/Products/Debug 2>/dev/null || ls -d .build/debug)
echo "== selftest (instrumentiert)"
swift build -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping >/dev/null 2>&1
LLVM_PROFILE_FILE="$out/selftest-%p.profraw" MIX741_SELFTEST=1 MIX741_NOEXT=1 .build/debug/minos741 2>&1 | grep -E "SELFTEST" || true
if [ -n "$(ls $prod/codecov/*.profraw 2>/dev/null)" ]; then cp "$prod"/codecov/*.profraw "$out"/; fi
xcrun llvm-profdata merge -sparse "$out"/*.profraw -o "$out/merged.profdata"
set --
for b in "$prod"/*.xctest; do n=$(basename "$b" .xctest); set -- "$@" -object "$b/Contents/MacOS/$n"; done
set -- "$@" -object .build/debug/minos741
first="$2"; shift 2
xcrun llvm-cov report "$first" "$@" -instr-profile "$out/merged.profdata" 2>/dev/null > "$out/report.txt"
python3 -I - "$out/report.txt" <<'PY'
import sys,collections
tot=collections.defaultdict(lambda:[0,0])
for l in open(sys.argv[1],encoding='utf-8',errors='replace'):
    if not l.startswith('Sources/'): continue
    p=l.split()
    try: lines,missed=int(p[7]),int(p[8])
    except: continue
    t=p[0].split('/')[1]
    if t in ('LinkKit','VST3SDK'): continue
    tot[t][0]+=lines; tot[t][1]+=missed
print('%-12s %8s %8s'%('target','zeilen','abdeckung'))
for t,(n,m) in sorted(tot.items()): print('%-12s %8d %7.1f %%'%(t,n,100*(n-m)/n if n else 0))
N=sum(v[0] for v in tot.values()); M=sum(v[1] for v in tot.values()); print('%-12s %8d %7.1f %%'%('gesamt',N,100*(N-M)/N))
PY
echo "bericht: $out/report.txt"
