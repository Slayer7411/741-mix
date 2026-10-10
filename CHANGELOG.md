# CHANGELOG

all notable changes. format: [keep a changelog](https://keepachangelog.com), versions: [semver](https://semver.org).
`0.x` -> anything can still change.

## ◆ [UNRELEASED]

### added
* key readout above each deck: open key of the track, the audible key in red as soon as it deviates (`8m → 3m`), the deviation in semitones below (keylock off: from the tempo, keylock on: from the key shift)
* SEMI in the master clock: every newly loaded track takes the tempo of the current master (clock or master deck, nearest half / double ratio), no phase lock
* quit asks first (⌘Q / quit menu) -> session, history and played state are written before the app closes
* own history files named by day and session: `history_2026-10-10-01.nml`, `-02`, … (shown as `2026-10-10 · 01`); the optional copy into the collection's history folder keeps its time-stamped name
* controller: flux held + pads 1-4 = hotcues 5-8 (set / jump, shift = delete), pads show their colors while flux is held. setting: beatjump on pads 3 / 4 instead
* browser: RUNNING TRACKS under the collection -> the tracks loaded on the decks
* bar counter: ↺ button next to it -> current beat = bar 1
* browser: played column ▶ in front (✓ = played since the last reset), right click on TRACK COLLECTION -> Reset Played State
* engine tests without an audio device (`swift test`): transport, seek, loop, reverse, keylock, delay tail, limiter, clock, track handoff, decode (direct, mono, rate conversion)
* ci: build + tests on every push and pull request, badge in the readme

### changed
* reverb softer: input diffusion, damped and slowly modulated comb filters, gentle lowpass at the output -> no metallic ringing, made for blends
* waveform: highs layer more visible (flat mapping of the high band, hats stay visible under kick and bass)
* waveform: rendered as bitmap tiles around the playhead on a background thread, grid and cues stay vector layers -> the render server no longer redraws thousands of path points per frame (main thread spent ~65 % waiting for it, now ~0 %)
* decks get an explicit height -> swiftui layout per state change 190 ms -> ~50 ms with 4 decks (two flexible decks per column made every button press freeze the ui); each deck mirrors its own state -> a change on deck A no longer re-renders B, C, D
* history and session files are written off the main thread (was a small hitch every 5 s while playing)
* readme, docs, release notes and ui texts without third-party product names; `MIX741_NOXONE` -> `MIX741_NOEXT`, external interface = first device with 8+ outputs
* settings: the waveform palette CLASSIC (renamed) and the history-copy toggle (renamed key) fall back to their defaults once after this update
* `MIX741_DEBUG=1` logs main thread hitches (`[hitch]`) and load times (`[load]`)
* browser search: ~35 ms -> ~1.5 ms per keystroke (14k tracks, prepared search text), accents ignored. the list is sorted once per source, a keystroke only filters (was: sort on every keystroke)
* track loading: decoded in chunks straight into the deck buffer -> one copy in memory instead of two or three while loading
* waveform: no core animation transaction while the deck stands still
* controller: mode = fx on / off instead of cycling effects, shift + mode = next effect / delay time
* fx off = spillover -> delay and reverb get no new audio but ring out
* reverb (single): SIZE / HP / LP, the filters only feed the reverb, the track stays dry, D/W = how much goes in -> bright swipe from the highs, long tail (size 1 ≈ 20 s), full D/W ≈ 5 dB over the track
* stopped deck keeps rendering until echo / reverb are really silent (was cut after 4 s)

### fixed
* auto master sticks to the running master deck: starting another deck no longer makes it master (the lowest deck letter won before)
* track handoff to the audio thread: generation counter instead of guessing the free slot -> the old buffer can no longer be freed while the audio thread still reads it
* level meter: both channels (was left only)

## ◆ [0.7.0] · 2026-10-10 · DMG

### added
* universal dmg (apple silicon + intel) attached to every release, built by a github action
* homebrew: `brew install --cask slayer7411/tap/minos-741`
* controller: sync held + hotcue 3 / 4 = one bar back / forward, inside a loop the loop stays and the position wraps
* audio: sample rate (44.1 - 192 khz, what the device offers) and buffer size, reconnect button (settings + status bar)
* docs: user manual (`docs/MANUAL.md`), docs index, new screenshot

### changed
* waveform drawn as vectors at screen resolution -> sharp at any zoom, sharp attack, height = file level (0 dBFS = full)
* spectrum colors mixed additive
* beatgrid: hairline beats, bar lines with caps top and bottom

### fixed
* audio: device running at a different rate than the core played too fast (96 vs 44.1 khz) -> coreaudio converts now

## ◆ [0.6.0] · 2026-10-10 · LINK

### added
* link 3.1.5 (network tempo sync) -> minos leads tempo and bar, peers shown
* link beat timestamped in the audio callback, smoothed phase correction, offset setting
* version + build hash in the window title
* sponsor button, discussions

### changed
* license -> GPL-2.0-or-later (link library)

## ◆ [0.5.0] · 2026-10-10 · BROWSER + FX

### added
* all library columns -> movable, hideable, saved
* analyzed check, tag highlight colors, smartlist from tags
* bar counter from the first play, 8 / 16 / 32 bar markers
* 4 fx units (2 / 4 switchable), single mode, channel fx assign 1-4
* controller fx sections per controller
* sync modes: dynamic / fixed / tempo only
* english ui

### fixed
* reverse keeps sync
* faster browser toggle, tolerant settings load

## ◆ [0.4.0] · 2026-10-10 · GPU WAVEFORM

### added
* classic deck layout, grid tools, cue colors
* hotcue + grid edits saved (own file, collection untouched)
* playlist export, controller per browser pane, big browser, gold master frame
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
* master clock: clock in the dsp core, AUTO / MASTER, tempo drag and ±, tap, metronome, snap and quant split
* app bundle: `scripts/make-app.sh` -> /Applications

### changed
* renamed 741-mix -> MINOS-741 (repo, app, data folder, docs, banner), settings and data migrate

## ◆ [0.2.0] · 2026-10-10 · C++ CORE

### added
* c++ realtime dsp (`MixDSP`) on a single coreaudio output
* time-stretch library for keylock

### fixed
* ui hangs: cached browser rows, coalesced encoder steps, file checks once at load, less redraw

## ◆ [0.1.0] · 2026-10-10 · FIRST BOOT

### added
* `collection.nml` import (14,160 tracks in 0.9 s), playlists, smartlists
* dual browser with role chips, tag system on comment 2
* 4 decks: cue / cup, hotcues, loops, beatjump, sync + master, keylock, flux, reverse
* internal mixer + external mode (one usb pair per deck)
* 2 fx units: filter / delay / reverb
* native hid controllers (two units), custom mappings
* history + preparation as nml

[UNRELEASED]: https://github.com/Slayer7411/MINOS-741/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/Slayer7411/MINOS-741/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/Slayer7411/MINOS-741/releases/tag/v0.1.0
