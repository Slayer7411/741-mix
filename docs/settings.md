# SETTINGS

everything under ⌘, saved as json in the user defaults (`prefs.v1`).

## ◆ LAYOUT

* window resizable, min 720 × 520, default 820 × 640
* sidebar left: DECKS · MIXER & FX · PLUGINS · DISPLAY · BROWSER · AUDIO · CONTROLLER · TAGS · CLOUD · KEYBOARD, active section with red bar
* page right, scrolls: `◆ SECTION` heading with hairline, rows with fixed label column left, control right
* toggles as squares (red = on), sliders with value + unit (s, ms, pt), hints in small mono
* controller: one block per unit (side, left / right deck, browser pane, fx unit, blink, startup show)
* new section = one line in `SettingsView.tabs`

## ◆ DECKS

* snap (cues, loops) and quant (jumps keep the phase)
* hotcue jump keeps the beat phase
* load position: load cue / grid, track start or hotcue 1
* track end warning (seconds, 0 = off)
* keylock on for the first load, default tempo range (±6 … ±100 %)
* phase lock while synced, sync mode: dynamic / fixed / tempo only, pitch bend amount
* metronome output pair
* default loop size and beatjump size
* loop snap (only with snap on): to loop cues (on, window 1-8 beats, default 4) and to the 4-bar grid (on, tolerance 1-8 beats, default 1)
* align grid anchor to phrases: off / suggest (default) / automatic -> on load the anchor is checked against the track's 8-bar structure, see manual 05
* history: played after x seconds audible, optional copy into the collection's history folder
* decks shown 1 / 2 / 4 (`ui.deckCount`, older `showFourDecks` is read once), preview start position in the browser
* groove → midi (`groove`): midi source name (default `MINOS-741 Groove`), channel bass (1) / drums (10), bass octave 0-3 (C3 = 60, default 1), length without loop 1 / 2 bars (default 2), offset −100…100 ms. instrument and style of the deck row are saved here too

## ◆ MIXER & FX

* show internal mixer
* headroom internal / external (−3 dB default), auto-gain external, main volume external
* auto-gain from the collection loudness
* eq kill (knob fully left = off)
* crossfader curve: smooth / sharp cut
* channel filter resonance
* show fx units, 2 or 4 units, delay feedback, fx filter resonance
* reverb level (dB, 0 = reverb ~4 dB below the track at full d/w), reverb brightness (dark -> airy: high decay 35 … 90 %, low cut 150 … 400 Hz, high shelf −4 … +6 dB, default 0.6), reverb pre-delay (ms)
* fx mapping: per unit D/W, knob 1-3, button 1-3 -> parameter of the loaded effect (menu, search field above), all to default. same menu as the right click on the unit
* remembered mappings per effect / plugin id (`engine.fxMappings`), forget per entry. a unit keeps its own mapping in the session

## ◆ PLUGINS

saved as json in `~/Library/Application Support/MINOS-741/plugins.json`, not in the user defaults.

* load third-party plugins isolated (on): separate system service for audio units, apple plugins and VST3 always in-process
* folders: system and user audio unit folders + AUv3 + system and user VST3 folders (always), own folders (add / remove), install plugin … (`.component` and `.vst3`), rescan
* list with search: per plugin use in MINOS-741 (on / off), status, PRÜFEN (auval / VST3 self-check), click -> path, load default / isolated / in-process (audio units), `läuft im prozess` (VST3), unblock, last log
* ALLE PRÜFEN with progress and cancel, results kept per plugin + version
* crash marker `plugin-opening.json` next to it, a leftover marker blocks that plugin on the next start -> [manual](MANUAL.md#-08--fx)
* offscreen image of this tab without audio: `MIX741_SELFTEST=1 MIX741_SHOT=plugins:<folder>` (optional `MIX741_SHOT_PLUGINS=<plugin folder>`)

## ◆ DISPLAY

* view: decks shown (1 / 2 / 4), preview start, gap between decks 0-12 pt (0 = waveforms end at the deck frame and the window edge)
* profiles: list (rename, apply, update, ↑ / ↓, ✕), save current view -> [manual](MANUAL.md#view-profiles). `ui.layoutProfiles`, `ui.activeLayoutProfile`
* waveform style: 3-band blend (default) / spectrum (6 bands) / mono; palette (not for spectrum): spectrum (rgb, default) / 741 bone / orange / blue / classic; high emphasis 0-3
* palette: 741 bone, orange, blue / white, classic (not for spectrum fine, it has fixed band colors -> [manual](MANUAL.md#-05--waveform--grid))
* high emphasis (spectrum fine): 0-2, default 1
* zoom (seconds per side), minimum height (grows with the window), dim the played part
* beatgrid: on / off, colorful (phrases, bars, beats), phrase length 16 / 32 / 64 / 128 beats, bar numbers
* cue colors: start cue red, cues white, loops green, 1-2 bar loops magenta
* magenta markers every 8 / 16 / 32 bars
* tag separator for comment 2, empty = space
* browser layout, hide the tree while decks are visible
* cover: in the deck header (on), preview of the selected track below the browser tree (on). the browser column `Cover` is switched via right click on the list header
* music folders for MUSIC FOLDERS: add / remove, empty = automatic (the folder holding 90 % of the collection's files)
* write browser edits into the collection file (off): backup at most once per hour into `Backup MINOS-741`, not while the library software runs -> [manual](MANUAL.md#-09--browser)
* browser preview: full row, two lines (default) / own column / behind the title / off
* preview colors: spectrum red / green / blue (default) / like the waveform
* compute previews in the background: always, throttled while a deck plays (default) / only while no deck plays / off -> [manual](MANUAL.md#preview)
* collection check: check on start (off), scan the music folders for files without a collection entry (on) -> [manual](MANUAL.md#check-the-collection)
* zoom of the main window: 50-200 %, also ⌘+ / ⌘− / ⌘0 -> [manual](MANUAL.md#-03--screen)
* language: system / english / german (after restart)
* status bar: load meters DSP · latency · dropouts · memory · cpu (on) -> [manual](MANUAL.md#status-bar)
* cancel loading after x s without audio data (4 s, 2-15)

## ◆ BROWSER

* harmony to the master: color the key column (on) -> [manual](MANUAL.md#harmony--matching)
* ◆ PASST (matching): which steps count besides the same key: ±1 on the wheel (on), relative major / minor (on), energy ±2 (off). bpm window ±1-10 % (±4), half / double tempo (off)
* saved under `ui.harmonyColors` and `ui.match`

## ◆ AUDIO

* output device (the system default or any device, saved by uid)
* sample rate (what the device offers, applies to the device right away, inside minos from the next start) and buffer size
* reconnect -> restarts the output, also via ↻ in the status bar
* audio core: decks in parallel (deck A on the audio thread, B-D on real-time workers in the device workgroup, same output; default off, for the load test) -> [manual · audio core](MANUAL.md#audio-core-decks-in-parallel)
* mode: internal (mixer in the app) or external (mixing desk)
* internal: which pair the master goes to
* external: one pair per deck, default a 1/2 · b 3/4 · c 5/6 · d 7/8
* preview: channel pair of the browser preview (automatic: external -> first free pair after the decks, none free -> off; internal -> main output · any pair · off), preview volume -> [manual · preview output](MANUAL.md#preview-output)
* loading & cache: decoding in the file service (own process) or in the app. notice after (no audio data, 2-15 s, default 4), cancel loading after (15-300 s, default 60, file service only), decoded track cache (1-64 gb, default 8) + used size -> [architecture · file service](architecture.md#-file-service)

## ◆ CLOUD

library in a cloud folder -> [library · cloud libraries](library.md#-cloud-libraries)

* state: local · online only · missing, time and duration of the last check, CHECK NOW
* keep local while MINOS-741 runs: off / preparation + open playlists + decks (default) / whole library. open playlists = playlists and smartlists in the browser panes up to 1000 tracks
* parallel downloads 1-4 (2), keep at least 5 / 10 / 20 / 50 gb free (10)
* on quit hand open downloads to the provider (on)
* library folder, available offline (pinned / not / unknown, all local), SHOW IN FINDER, CHECK. pinning is done in the finder: right click -> make available offline

## ◆ KEYBOARD

* every app shortcut, grouped: decks, browser, view, general -> table in [MANUAL · keys](MANUAL.md#-12--keys)
* click a shortcut, press the new key -> applies right away, esc = cancel
* ✕ = no shortcut, ↺ = back to default, RESET ALL
* a key used twice turns red, the first action in the list wins
* ⌘Q, ⌘H, ⌘M, ⌃⌘F stay with the system
* saved under `shortcuts` (action id -> key, e.g. `"browser.resetplayed": "opt+cmd+p"`), only keys that differ from the default

## ◆ CONTROLLER

* controllers: name, serial number, side (left a / c, right b / d, saved per device, swaps the other unit), decks per unit (left / right), browser pane and fx unit per unit, blink to identify, startup show per device
* startup show on connect on / off (default on)
* cue action: flux reverse / cue / reverse
* flux button: switch pad layer (hotcues 5-8, default; shift + flux = flux mode) / flux mode (tap toggles flux mode if enabled)
* flux held + pads: hotcues 5-8 or beatjump on pads 3 / 4, beatjump size for flux + hotcue 3 / 4
* touch strip: bend or seek, sensitivity
* browse step with shift
* browse push: big browser (default) / matching on / off
* led brightness on / off, cue and loop pad colors
