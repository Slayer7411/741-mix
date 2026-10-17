#!/bin/zsh
# Codename zur Hauptversion: scripts/codename.sh 0.8.2 -> LIMBUS
# Kopie von Sources/MixCore/Codename.swift (CodenameTests prüft die Liste). Ungültige Version -> Fehler (1)
set -euo pipefail
names=(LIMBUS LUXURIA GULA AVARITIA IRA HAERESIS VIOLENTIA FRAUS PRODITIO PURGATORIUM PARADISUS)
v=${1:-}
v=${v#v}
[[ $v =~ '^[0-9]+(\.[0-9]+){0,2}$' ]] || { print -u2 "codename.sh: keine version: ${1:-}"; exit 1 }
major=${v%%.*}
major=$(( 10#$major ))
(( major >= $#names )) && major=$(( $#names - 1 ))
print -r -- "$names[$(( major + 1 ))]"
