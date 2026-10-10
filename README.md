<p align="center"><img src="docs/assets/banner.svg" alt="MINOS-741" width="100%"></p>

native dj software for macos. built to replace traktor for my own sets -> same workflow, same files, but with the browser and tag system i actually want.

<p align="center"><img src="docs/assets/screenshot.png" alt="MINOS-741 with 4 decks, external mixer mode and dual browser" width="100%"></p>

## ◆ WHAT IT DOES

* 4 decks with the traktor deck set: cue / cup, 8 hotcues, auto + manual loops, beatjump, sync + master, keylock, key shift, flux, reverse, flux reverse, pitch bend
* sync runs on its own control thread -> phase stays locked even if the ui hangs
* waveform as pre-rendered tiles, 3-band layers, beatgrid with bar marks, phrase bands and a phrase countdown at the playhead
* internal mixer (gain, auto-gain, 3-band eq with kill, filter, fader, crossfader) or external mixer mode -> every deck on its own usb pair (tested with a xone:96)
* 2 fx units in traktor group mode: filter / delay (beat synced) / reverb
* traktor kontrol x1 mk2 in native hid mode, two units, my traktor custom mappings included
* dual browser side by side or stacked -> e.g. "basis" left, "layer" right
* reads traktor `collection.nml` directly: tracks, cues, grids, keys, playlists, smartlists
* tag system on comment 2 with a configurable separator
* history and preparation archive written as traktor nml -> import them straight into traktor
* every option has a setting (⌘,)

## ◆ STATUS

works on my machine, used for testing sets. not a finished product.
whats missing compared to traktor 3/4 is listed in [docs/feature-parity.md](docs/feature-parity.md).

## ◆ RUN IT

needs macos 15+ and xcode / swift 6.

```
git clone https://github.com/Slayer7411/MINOS-741.git
cd MINOS-741
swift run minos741
```

build a real app and install it to /Applications (release build, icon, ad hoc signed):

```
scripts/make-app.sh
```

the app looks for `~/Native Instruments/Traktor 3.11.2/collection.nml` -> other files via ⌘O.
tests: `swift test` (parses a sample nml, all smartlists of a real collection if present, history round trip).

silent self test of the engine (no sound, plays two tracks, checks sync / loop / beatjump / fx levels and blocks the main thread for 3s):

```
MIX741_SELFTEST=1 MIX741_NOXONE=1 swift run minos741
```

## ◆ DOCS

* [architecture](docs/architecture.md) -> threads, audio graph, why the ui can hang without the sound stopping
* [library](docs/library.md) -> dual browser, tags, smartlists, preparation, history
* [traktor files](docs/traktor-files.md) -> collection.nml, history nml, preparation, tsi controller config
* [kontrol x1 mk2](docs/controllers-x1-mk2.md) -> hid layout, mapping, leds
* [settings](docs/settings.md)
* [feature parity with traktor](docs/feature-parity.md)

## ◆ DESIGN

the ui follows my design system ci-741:
* void / chitin black, bone white text
* red only as state (playing, sync, loop, fx on), purple for master and phrases
* cinzel in caps for labels, ibm plex mono for data
* radius 0, 1px hairlines, unicode instead of icons

fonts are bundled under the sil open font license (see `Sources/MixApp/Resources/Fonts`).

## ◆ CREDITS

* x1 mk2 hid byte layout from the mixxx hid mapping by infiniteloop -> [mixxx forum](https://mixxx.discourse.group/t/traktor-kontrol-x1-mk2-hid-mapping-v2-1-mixxx-2-5-x-2-7-alpha-complete-archive/34064)
* traktor tsi command ids from [cmdr](https://github.com/cmdr-editor/cmdr)
* fonts: [cinzel](https://fonts.google.com/specimen/Cinzel), [ibm plex mono](https://fonts.google.com/specimen/IBM+Plex+Mono)

traktor and kontrol are trademarks of native instruments. this project is not affiliated with them and contains no native instruments code.
