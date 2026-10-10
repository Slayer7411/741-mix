#!/bin/zsh
# Test-Plugin bauen: das Beispiel "again_sampleaccurate" aus dem VST 3 SDK (gleicher Stand wie Sources/VST3SDK)
# als .vst3-Bundle nach <ziel>. Nur für Tests – nie in ~/Library/Audio installieren.
# Aufruf: scripts/build-vst3-fixture.sh <ziel-ordner>
set -euo pipefail
ROOT=${0:A:h:h}
OUT=${1:?ziel-ordner fehlt}
HOST=$ROOT/Sources/VST3SDK
FIX=$ROOT/Tests/Fixtures/VST3Plugin
SAMPLE=$FIX/public.sdk/samples/vst/again_sampleaccurate/source
NAME=again-sampleaccurate
BUNDLE=$OUT/$NAME.vst3
OBJ=$OUT/obj
mkdir -p $OBJ $BUNDLE/Contents/MacOS

SOURCES=(
  $HOST/pluginterfaces/base/*.cpp
  $HOST/public.sdk/source/vst/vstinitiids.cpp
  $HOST/public.sdk/source/common/commoniids.cpp
  $FIX/base/source/*.cpp
  $FIX/base/thread/source/*.cpp
  $FIX/public.sdk/source/main/pluginfactory.cpp
  $FIX/public.sdk/source/main/moduleinit.cpp
  $FIX/public.sdk/source/main/macmain.cpp
  $FIX/public.sdk/source/common/pluginview.cpp
  $FIX/public.sdk/source/vst/*.cpp
  $FIX/public.sdk/source/vst/utility/testing.cpp
  $SAMPLE/*.cpp
)
FLAGS=(-std=c++17 -O1 -DRELEASE=1 -fvisibility=hidden -I$HOST -I$FIX -I$FIX/minos -I$SAMPLE -w)

# parallel übersetzen, dann zum Bundle binden
print -l $SOURCES | xargs -P 8 -I{} sh -c 'f="$1"; shift; o="'$OBJ'/$(echo "$f" | shasum | cut -c1-12).o"; xcrun clang++ "$@" -c "$f" -o "$o"' _ {} $FLAGS
xcrun clang++ -bundle -o $BUNDLE/Contents/MacOS/$NAME $OBJ/*.o \
  -exported_symbols_list $FIX/public.sdk/source/main/macexport.exp \
  -framework CoreFoundation -framework Foundation
cat > $BUNDLE/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>org.minos741.test.again-sampleaccurate</string>
  <key>CFBundleName</key><string>again-sampleaccurate</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
</dict>
</plist>
PLIST
printf 'BNDL????' > $BUNDLE/Contents/PkgInfo
codesign -s - -f $BUNDLE >/dev/null 2>&1 || true
rm -rf $OBJ
print $BUNDLE
