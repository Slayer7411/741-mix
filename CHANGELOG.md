# CHANGELOG

all notable changes. format: [keep a changelog](https://keepachangelog.com), versions: [semver](https://semver.org).
`0.x` -> anything can still change.

## ◆ [UNRELEASED]

### added
* cover art: square cover left of the title in each deck header, preview of the selected track below the browser tree, optional `Cover` column in the list (hidden by default). source: embedded picture (mp3, m4a, flac), else `cover` / `folder` / `front` .jpg / .png in the track's folder. read and scaled in the background, thumbnails cached in `~/Library/Caches/MINOS-741/artwork`, list rows load only while visible. settings: ⌘, -> DISPLAY -> cover
* phrase anchor: on load the track's structural changes are checked against 8-bar boundaries from the grid anchor -> a cut first hit or a pickup beat (anchor 1-3 beats off) is found and the anchor moves by whole beats, bpm and grid lines stay. setting off / suggest (red `PHRASE +n` in the grid row) / automatic, stored in minos's own edits, never in the collection
* grid row: ◂4 ◂1 1▸ 4▸ move the anchor by 1 bar / 1 beat (renumbering only)
* code readout above each deck: bar of the track in its phrase (`5/16`) against the bar counter. purple `◆ CODE` = in the code, red `+2 BARS` / `−3 BEATS` = how far it is off, grey = deck stopped. phrase start = grid anchor, phrase length = the waveform phrase (4 / 8 / 16 / 32 bars)
* settings: KEYBOARD tab -> every shortcut can be changed (click, press the new key), removed or reset, a key used twice turns red; changes apply right away
* browser: right click a track -> Reset Played State (any source), shortcut ⌥⌘P, also in the new BROWSER menu
* new shortcuts on the focused deck: cue ⌥⌘C (hold), cup ⌥⌘V, hotcues 1-8 ⌃⌘1-8; assignable without default: master, keylock, reloop, load / preview selection, reload collection, reconnect audio
* browser: MUSIC FOLDERS in the tree -> the music library on disk, folder by folder. collection files show their metadata, other audio files show grey and load anyway. SUBFOLDERS switch, rescan on right click and on changes, folders per pane saved in the session, own folders under ⌘, -> DISPLAY -> browser (default: the folder holding 90 % of the collection)
* fx single mode: PLUGIN -> any installed audio unit effect (apple or third-party, v2 and v3), e.g. AUMatrixReverb / AUReverb2. knobs 1-3 = first three plugin parameters, D/W, ON with spillover (tail rings out), EDIT opens the plugin window (own view or generic), plugin and settings saved with the session
* browser: edit track metadata -> inline (click a selected row again or return, tab = next column, esc = cancel), edit window via right click -> `Bearbeiten …` / ⌘E with PREV / NEXT, RESTORE · CANCEL · APPLY · OK, several tracks at once with "apply to all" boxes and `‹mehrere›` for different values. fields: title, artist, release, mix, remixer, producer, label, catalog no, genre, comment 1 + 2, key text, track #, release date, bpm (not when locked), rating. list, search and sorting follow right away
* edits saved in `metadata.json`, laid over the collection on every load, right click -> `Eigene Änderungen verwerfen`
* setting: write the edits into the collection file (off by default) -> only the edited entries change, byte for byte the rest, backup `Backup MINOS-741/collection_….nml` at most once per hour, atomic, never while the library software runs
* browser: mix column (hidden by default)
* key readout above each deck: open key of the track, the audible key in red as soon as it deviates (`8m → 3m`), the deviation in semitones below (keylock off: from the tempo, keylock on: from the key shift)
* SEMI in the master clock: every newly loaded track takes the tempo of the current master (clock or master deck, nearest half / double ratio), no phase lock
* SEMI: an unsynced deck starts in phase with the running master (play, cup, cue preview) -> one jump to the nearest beat at start, then it runs free with its own tempo
* quit asks first (⌘Q / quit menu) -> session, history and played state are written before the app closes
* own history files named by day and session: `history_2026-10-10-01.nml`, `-02`, … (shown as `2026-10-10 · 01`); the optional copy into the collection's history folder keeps its time-stamped name
* controller: flux held + pads 1-4 = hotcues 5-8 (set / jump, shift = delete), pads show their colors while flux is held. setting: beatjump on pads 3 / 4 instead
* browser: RUNNING TRACKS under the collection -> the tracks loaded on the decks
* bar counter: ↺ button next to it -> current beat = bar 1
* browser: played column ▶ in front (✓ = played since the last reset), right click on TRACK COLLECTION -> Reset Played State
* engine tests without an audio device (`swift test`): transport, seek, loop, reverse, keylock, delay tail, limiter, clock, track handoff, decode (direct, mono, rate conversion)
* ci: build + tests on every push and pull request, badge in the readme
* reverb settings (⌘, -> MIXER & FX): level (−18 … +6 dB), brightness, pre-delay (0 … 120 ms, default 15 ms)

### changed
* deck: hotcues, loop sizes 1/32 … 32 and beatjump sizes 1/4 … 64 in three full-width rows, the selected loop and beatjump size red (follows the controller too), LOOP = on / off, white / yellow pads with dark numbers. `MIX741_SHOT=deck:<png>` (selftest only) renders a deck offscreen
* settings window redone: sidebar instead of tabs, resizable (min 720 × 520), `◆` section headings, fixed label column, square toggles, slider values with units, one block per controller; selftest renders it offscreen (`MIX741_SHOT=settings:<folder>`)
* big browser ⇄ decks (space / browse push) faster: hidden decks keep their size (no new deck layout, no new waveform tiles), the playlist tree stays in its split at width 0 instead of being removed and re-inserted -> back to decks 939 -> 194 ms, to big browser 328 -> 266 ms (2 browsers side by side, tree only in big browser, 4 decks), 145 / 144 -> 98 / 107 ms with one browser. `MIX741_DEBUG=1` logs `[toggle]` (switch to next frame), `MIX741_BENCH=toggle` measures offscreen without a window
* reverb softer: input diffusion, damped and slowly modulated comb filters, gentle lowpass at the output -> no metallic ringing, made for blends
* waveform: markers slightly stronger -> loop frame 1.5 pt + denser tint, play head, cues, phrases, anchor and 8/16/32 markers +0.5 pt, beat lines on whole pixels, ruler ticks, caps and bar numbers brighter. check without a window: selftest + `MIX741_SHOT=wave:<png>`
* reverb level: no fixed +10 dB boost in single mode anymore. full d/w on pink noise: track + reverb 4.2× -> 1.2× the dry level (reverb alone +12 dB -> −4 dB), group mode 1.8× -> 1.2×
* reverb darker by default: 200 Hz low cut before the reverb (no bass build-up), output lowpass 12 dB/oct, ~4.7 kHz at the default brightness
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
* controller events are logged (`[hid]`) only with `MIX741_DEBUG=1` (was one stdout write per knob step on the control thread)
* offline core bench: `MIX741_BENCH=1 swift test --filter benchRenderCPU` -> 2 decks keylock 1.5 % of one core (avg 44 µs, max ~0.5 ms per 128-frame block), 4 decks keylock + fx 3.4 % (max ~1 ms of 2.9 ms at 128 frames), m1 pro
* fx off = spillover -> delay and reverb get no new audio but ring out
* reverb (single): SIZE / HP / LP, the filters only feed the reverb, the track stays dry, D/W = how much goes in -> bright swipe from the highs, long tail (size 1 ≈ 20 s), full D/W ≈ 5 dB over the track
* stopped deck keeps rendering until echo / reverb are really silent (was cut after 4 s)

### fixed
* closing the main window (red button, ⌘W) quits after the confirmation instead of leaving minos running without a window
* tag colors were lost after a restart (empty map in the defaults dropped the saved entries)
* auto master sticks to the running master deck: starting another deck no longer makes it master (the lowest deck letter won before)
* track handoff to the audio thread: generation counter instead of guessing the free slot -> the old buffer can no longer be freed while the audio thread still reads it
* level meter: both channels (was left only)
* loading two tracks onto one deck in quick succession: the last chosen one stays (a slower decode of the first one finishing later replaced it)
* usb interface dropout: when the interface chosen in settings comes back, the output returns to it by itself (stayed on the fallback device until ↻)
* audio core: nan/inf from a broken file or an unstable state no longer reaches the device and no longer silences the deck until the next load -> the block is dropped, the deck resets its filters / fx / stretch and fades back in
* audio core: devices at 16-32 khz -> channel filter and high eq stay stable (filter frequencies above nyquist made the deck go silent)
* audio core: denormals flushed to zero inside the render block (decaying eq / filter / fx tails cost up to ~100x per sample on intel macs)
* audio core: render with 0 channels, tracks reporting rate 0 -> no crash / no division by zero; inf / nan bpm in the collection -> track loads without grid instead of crashing the bar readout
* waveform: a newly loaded track could show the waveform of an earlier one (cache keyed by a reused buffer address); waveforms of unloaded tracks are freed right away (were kept up to 16)
* deck state on screen kept updating only outside menus: the 30 hz mirror now also runs while a menu is open or the window is resized

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
