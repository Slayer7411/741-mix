<p align="center"><img src="docs/assets/banner.svg" alt="MINOS-741" width="100%"></p>

<p align="center"><a href="https://github.com/Slayer7411/MINOS-741/releases"><img src="https://img.shields.io/github/v/release/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=%24MINOS" alt="release"></a> <a href="https://github.com/Slayer7411/MINOS-741/blob/main/CHANGELOG.md"><img src="https://img.shields.io/badge/CHANGELOG-%E2%97%86-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="changelog"></a> <a href="docs/MANUAL.md"><img src="https://img.shields.io/badge/MANUAL-%E2%86%92-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="manual"></a> <a href="https://github.com/Slayer7411/MINOS-741/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/LICENSE-GPL--2.0+-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="license"></a> <img src="https://img.shields.io/badge/MACOS-15+-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="macos 15+"> <img src="https://img.shields.io/badge/SWIFT-6-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="swift 6"> <img src="https://img.shields.io/badge/C++-17-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="c++17"></p>
<p align="center"><a href="https://github.com/Slayer7411/MINOS-741/commits/main"><img src="https://img.shields.io/github/last-commit/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=LAST%20COMMIT" alt="last commit"></a> <a href="https://github.com/Slayer7411/MINOS-741/graphs/contributors"><img src="https://img.shields.io/github/contributors/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=CONTRIBUTORS" alt="contributors"></a> <a href="https://github.com/Slayer7411/MINOS-741/discussions"><img src="https://img.shields.io/github/discussions/Slayer7411/MINOS-741?style=flat-square&labelColor=0a0a0a&color=e8e4d8&label=DISCUSSIONS" alt="discussions"></a> <a href="https://github.com/sponsors/Slayer7411"><img src="https://img.shields.io/badge/SPONSOR-%E2%99%A5-e8e4d8?style=flat-square&labelColor=0a0a0a" alt="sponsor"></a></p>

```
$MINOS  v0.7.0 ▲  ·  CPU 70% -> 13% ▼  ·  PHASE 0.0000 BEATS  ·  14,160 TRACKS / 0.9 S  ·  LINK ●  ·  X1 MK2 ×2
```

native dj software for macos. traktor workflow and files, own browser and tag system.
built for my own setup. ideas -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions), own needs -> fork it.

<p align="center"><img src="docs/assets/screenshot.png" alt="MINOS-741 with 4 decks, external mixer mode and dual browser" width="100%"></p>

## ◆ WHAT IT DOES

* 4 decks with the traktor deck set: cue / cup, 8 hotcues, auto + manual loops, beatjump, sync + master, keylock, key shift, flux, reverse, flux reverse, pitch bend
* c++ audio core, sync on its own thread -> ui can hang, sound and sync keep running
* master clock with AUTO / MASTER, tap, metronome, snap and quant, ableton link (minos leads)
* bar counter from the first play (4 / 8 / 16 bars)
* sync modes: dynamic, fixed (keeps a shifted phase), tempo only
* gpu waveform with 3-band layers, real file level, colored beatgrid, phrase countdown, grid tools
* internal mixer or external mode -> every deck on its own usb pair (xone:96)
* 2 or 4 fx units, group or single mode, channel assign 1-4
* two kontrol x1 mk2 in native hid mode, incl. my traktor custom mappings
* dual browser side by side or stacked, all traktor columns (move, hide, saved)
* reads traktor `collection.nml` directly
* tag system on comment 2 with a configurable separator
* history, preparation and playlist export as traktor nml
* hotcue and grid edits saved in an own file, collection untouched
* session restore after restart (decks, fx, clock, browser)
* every option has a setting (⌘,), ui in german or english

## ◆ STATUS

```
> minos --status
  core      ■ c++ realtime, lock-free, sync on its own thread
  decks     ■ 4 track decks, traktor deck set
  sync      ■ master clock · ableton link · 3 sync modes
  mixer     ■ internal + external (xone:96)
  fx        ◧ 4 units, 3 effects so far
  browser   ■ dual browser · all traktor columns · tags · smartlists
  x1 mk2    ■ native hid, 2 units
  analysis  □ bpm / key / grid come from the traktor collection
```

work in progress, `0.x` -> things still change. missing parts: [docs/feature-parity.md](docs/feature-parity.md).

## ◆ VERSIONING

* [semver](https://semver.org) tags `vX.Y.Z`, every release -> [releases](https://github.com/Slayer7411/MINOS-741/releases) + [CHANGELOG.md](CHANGELOG.md)
* app title shows version + build hash, e.g. `MINOS-741 0.7.0 (245e16c)`
* `main` = latest state, can be ahead of the last tag

## ◆ KEYS

| key | action |
|---|---|
| ⌘1-4 | focus deck a-d |
| ⌘space | play / pause |
| ⌘Y | sync |
| ⌘L | loop |
| ⌥⌘← / → | beatjump |
| ⌥⌘M | mixer on / off |
| ⌥⌘4 | 4 decks |
| ⌥⌘B | big browser |
| ⌘O | open collection |
| ⌘, | settings |

## ◆ INSTALL

needs macos 15+, apple silicon or intel.

```
brew install --cask slayer7411/tap/minos-741
```

or the dmg from [releases](https://github.com/Slayer7411/MINOS-741/releases/latest). not signed by apple -> first start: system settings -> privacy & security -> OPEN ANYWAY.

## ◆ RUN IT

from source, needs xcode / swift 6.

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

```
> minos --help
```

**[→ MANUAL](docs/MANUAL.md)** -> install, decks, sync, mixer, fx, browser, tags, keys, troubleshooting, faq

* [settings](docs/settings.md) · [kontrol x1 mk2](docs/controllers-x1-mk2.md) · [library](docs/library.md)
* [architecture](docs/architecture.md) · [traktor files](docs/traktor-files.md) · [feature parity](docs/feature-parity.md)
* [changelog](CHANGELOG.md) · [contributing](CONTRIBUTING.md) · [all docs](docs/README.md)

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
* [ableton link](https://github.com/Ableton/link)

traktor and kontrol are trademarks of native instruments. not affiliated, no native instruments code.

## ◆ CONTRIBUTING

bugs -> [issues](https://github.com/Slayer7411/MINOS-741/issues) · ideas -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions) · rules, setup, release checklist -> [CONTRIBUTING.md](CONTRIBUTING.md)

## ◆ LICENSE

GPL-2.0-or-later ([LICENSE.md](LICENSE.md)), because of ableton link.
* ableton link 3.1.5: GPL-2.0-or-later, `Sources/LinkKit`
* signalsmith stretch / linear: MIT
* fonts: SIL open font license
