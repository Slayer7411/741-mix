<p align="center"><img src="docs/assets/banner.svg" alt="MINOS-741" width="100%"></p>

<p align="center"><a href="https://github.com/Slayer7411/MINOS-741/graphs/contributors"><img src="https://img.shields.io/github/contributors/Slayer7411/MINOS-741?style=flat-square&label=CONTRIBUTORS&labelColor=0a0a0a&color=e8e4d8" alt="contributors"></a> <a href="https://github.com/sponsors/Slayer7411"><img src="https://img.shields.io/badge/SPONSOR-%E2%99%A5-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="sponsor"></a> <a href="https://github.com/Slayer7411/MINOS-741/discussions"><img src="https://img.shields.io/github/discussions/Slayer7411/MINOS-741?style=flat-square&label=DISCUSSIONS&labelColor=0a0a0a&color=e8e4d8" alt="discussions"></a></p>

native dj software for macos. traktor workflow and files, own browser and tag system.

<p align="center"><img src="docs/assets/screenshot.png" alt="MINOS-741 with 4 decks, external mixer mode and dual browser" width="100%"></p>

## ◆ WHAT IT DOES

* 4 decks with the traktor deck set: cue / cup, 8 hotcues, auto + manual loops, beatjump, sync + master, keylock, key shift, flux, reverse, flux reverse, pitch bend
* c++ audio core, sync on its own thread -> ui can hang, sound and sync keep running
* master clock with AUTO / MASTER, tap, metronome, snap and quant
* waveform with 3-band layers, colored beatgrid, phrase countdown, grid tools
* internal mixer or external mode -> every deck on its own usb pair (xone:96)
* 2 fx units in traktor group mode: filter / delay (beat synced) / reverb
* two kontrol x1 mk2 in native hid mode, incl. my traktor custom mappings
* dual browser side by side or stacked
* reads traktor `collection.nml` directly
* tag system on comment 2 with a configurable separator
* history, preparation and playlist export as traktor nml
* every option has a setting (⌘,)

## ◆ STATUS

work in progress. missing parts: [docs/feature-parity.md](docs/feature-parity.md).

## ◆ RUN IT

needs macos 15+ and xcode / swift 6.

```
git clone https://github.com/Slayer7411/MINOS-741.git
cd MINOS-741
swift run minos741
```

app bundle into /Applications:

```
scripts/make-app.sh
```

collection: `~/Native Instruments/Traktor 3.11.2/collection.nml`, others via ⌘O.
tests: `swift test`. engine self test:

```
MIX741_SELFTEST=1 MIX741_NOXONE=1 swift run minos741
```

## ◆ DOCS

* [architecture](docs/architecture.md)
* [library](docs/library.md)
* [traktor files](docs/traktor-files.md)
* [kontrol x1 mk2](docs/controllers-x1-mk2.md)
* [settings](docs/settings.md)
* [feature parity with traktor](docs/feature-parity.md)

## ◆ DESIGN

ci-741:
* void / chitin black, bone white text
* red only as state (playing, sync, loop, fx on), purple for master and phrases
* cinzel in caps for labels, ibm plex mono for data
* radius 0, 1px hairlines, unicode instead of icons

fonts bundled under the sil open font license.

## ◆ CREDITS

* x1 mk2 hid byte layout from the mixxx hid mapping by infiniteloop -> [mixxx forum](https://mixxx.discourse.group/t/traktor-kontrol-x1-mk2-hid-mapping-v2-1-mixxx-2-5-x-2-7-alpha-complete-archive/34064)
* traktor tsi command ids from [cmdr](https://github.com/cmdr-editor/cmdr)
* fonts: [cinzel](https://fonts.google.com/specimen/Cinzel), [ibm plex mono](https://fonts.google.com/specimen/IBM+Plex+Mono)

traktor and kontrol are trademarks of native instruments. not affiliated, no native instruments code.
