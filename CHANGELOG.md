# CHANGELOG

all notable changes. format: [keep a changelog](https://keepachangelog.com), versions: [semver](https://semver.org).
`0.x` -> anything can still change.

## ◆ [UNRELEASED]

## ◆ [0.6.0] · 2026-10-10 · LINK

### added
* ableton link 3.1.5 -> minos leads tempo and bar, peers shown
* link beat timestamped in the audio callback, smoothed phase correction, offset setting
* version + build hash in the window title
* sponsor button, discussions

### changed
* license -> GPL-2.0-or-later (ableton link)

## ◆ [0.5.0] · 2026-10-10 · BROWSER + FX

### added
* all traktor browser columns -> movable, hideable, saved
* analyzed check, tag highlight colors, smartlist from tags
* bar counter from the first play, 8 / 16 / 32 bar markers
* 4 fx units (2 / 4 switchable), traktor single mode, channel fx assign 1-4
* x1 fx sections per controller
* sync modes: dynamic / fixed / tempo only
* english ui

### fixed
* reverse keeps sync
* faster browser toggle, tolerant settings load

## ◆ [0.4.0] · 2026-10-10 · GPU WAVEFORM

### added
* deck layout like traktor 3, grid tools, cue colors
* hotcue + grid edits saved (own file, collection untouched)
* playlist export, x1 per browser pane, big browser, gold master frame
* gpu waveform (core animation layers, display link), beatgrid ruler with bar markers
* real file level (full height = 0 dBFS, no normalizing)
* session restore, headroom per mixer mode

### changed
* animations outside swiftui -> cpu 70 % -> 13 %
* fullscreen without toolbar

### fixed
* keylock phase error −0.27 -> 0.0000 beats

## ◆ [0.3.0] · 2026-10-10 · MINOS-741

### added
* master clock like traktor: clock in the dsp core, AUTO / MASTER, tempo drag and ±, tap, metronome, snap and quant split
* app bundle: `scripts/make-app.sh` -> /Applications

### changed
* renamed 741-mix -> MINOS-741 (repo, app, data folder, docs, banner), settings and data migrate

## ◆ [0.2.0] · 2026-10-10 · C++ CORE

### added
* c++ realtime dsp (`MixDSP`) on a single coreaudio output
* signalsmith stretch for keylock

### fixed
* ui hangs: cached browser rows, coalesced encoder steps, file checks once at load, less redraw

## ◆ [0.1.0] · 2026-10-10 · FIRST BOOT

### added
* traktor `collection.nml` import (14,160 tracks in 0.9 s), playlists, smartlists
* dual browser with role chips, tag system on comment 2
* 4 decks: cue / cup, hotcues, loops, beatjump, sync + master, keylock, flux, reverse
* internal mixer + external mode (one usb pair per deck)
* 2 fx units: filter / delay / reverb
* kontrol x1 mk2 native hid, traktor custom mappings
* history + preparation as traktor nml

[UNRELEASED]: https://github.com/Slayer7411/MINOS-741/compare/v0.6.0...HEAD
[0.6.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Slayer7411/MINOS-741/releases/tag/v0.1.0
