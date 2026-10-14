# SETTINGS

everything under ⌘, saved as json in the user defaults (`prefs.v1`).

## ◆ LAYOUT

* window resizable, min 720 × 520, default 820 × 640
* sidebar left, general -> special: AUDIO · DISPLAY · DECKS · MIXER & FX · PLUGINS · BROWSER · TAGS · CLOUD · KEYBOARD · CONTROLLER, active section with red bar
* own order: drag a sidebar entry onto another (lands above it) or below the last one. right click -> `Standard-Reihenfolge` = default. `ui.settingsTabOrder` (title keys, empty = default; a new section appears after its default predecessor)
* page right, scrolls: `◆ SECTION` heading with hairline, rows with fixed label column left, control right. sections within a page also general -> special
* toggles as squares (red = on), sliders with value + unit (s, ms, pt), hints in small mono
* controller: one block per unit (side, left / right deck, browser pane, fx unit, blink, startup show)
* new section = one line in `SettingsView.tabs`

## ◆ AUDIO

* output device (the system default or any device, saved by uid), channels
* sample rate (what the device offers, applies to the device right away, inside minos from the next start) and buffer size
* reconnect -> restarts the output, also via ↻ in the status bar
* mixer mode: internal (mixer in the app) or external (mixing desk)
* internal: which pair the master goes to
* external: one pair per deck, default a 1/2 · b 3/4 · c 5/6 · d 7/8
* preview: channel pair of the browser preview (automatic: external -> first free pair after the decks, none free -> off; internal -> main output · any pair · off), preview volume -> [manual · preview output](MANUAL.md#preview-output)
* loading & cache: decoding in the file service (own process) or in the app. notice after (no audio data, 2-15 s, default 4), cancel loading after (15-300 s, default 60, file service only), decoded track cache (1-64 gb, default 8) + used size -> [architecture · file service](architecture.md#-file-service)
* recording: source (`record.source`: automatic -> external = input from the desk, internal = internal master; input; master), input device (`record.inputUID`, empty = output device), input pair (`record.inputFirstChannel`, 0 = 1/2), show input level without recording (`record.showInputLevel`, off), format (`record.format`: apple lossless 24 bit / wav 24 bit / aiff 24 bit), folder (`record.folder`, empty = `~/Music/MINOS-741/Recordings`) -> [manual · recording](MANUAL.md#-16--recording)
* audio core: decks in parallel (deck A on the audio thread, B-D on real-time workers in the device workgroup, same output; default off, for the load test) -> [manual · audio core](MANUAL.md#audio-core-decks-in-parallel)

## ◆ DISPLAY

* language: system / english / german (after restart)
* zoom of the main window: 50-200 %, also ⌘+ / ⌘− / ⌘0 -> [manual](MANUAL.md#-03--screen)
* layout: decks shown 1 / 2 / 4 (`ui.deckCount`, older `showFourDecks` is read once), gap between decks 0-12 pt (0 = waveforms end at the deck frame and the window edge), browser layout, hide the tree while decks are visible
* profiles: list (rename, apply, update, ↑ / ↓, ✕), save current view -> [manual](MANUAL.md#view-profiles). `ui.layoutProfiles`, `ui.activeLayoutProfile`
* status bar: always / automatic / off, load meters DSP · latency · dropouts · memory · cpu (on) -> [manual](MANUAL.md#status-bar)
* waveform style: 3-band blend (default) / spectrum (6 bands) / mono
* 3-band blend: preset (built in: A-K, 741 bone, orange, blue / white, classic; own ones below) with NEW / COPY / RENAME / DELETE / RESET. fields: crossovers low 40-400 Hz, mid 200-2000 Hz or auto (geometric mean), high 1-8 kHz (log sliders), attack / release per band, analysis weight per band, rgb direct or three colors, held highs / held lows color, level per band, high emphasis, energy share, transitions, stack curve, saturation, orange / light blue amount. changing a built-in preset creates an own copy (`<name> Kopie`) and selects it. `ui.wavePreset`, own presets in `wave-presets.json` (MINOS-741 folder) -> [manual](MANUAL.md#-05--waveform--grid)
* spectrum / mono: palette (not for spectrum): spectrum (rgb, default) / 741 bone / orange / blue / classic; high emphasis 0-3 (spectrum)
* zoom (seconds per side), minimum height (grows with the window), dim the played part
* beatgrid: on / off, colorful (phrases, bars, beats), phrase length 16 / 32 / 64 / 128 beats, bar numbers, magenta markers every 8 / 16 / 32 bars, lines fine (default) / bold (`ui.gridLineWeight`) -> [manual](MANUAL.md#-05--waveform--grid)
* cue colors (screen and controller pads): start cue red, cues white, loops green, short loops (up to 1 / 2 / 4 / 8 bars) magenta

## ◆ DECKS

* play: snap (cues, loops) and quant (jumps keep the phase), hotcue jump keeps the beat phase, load position (load cue / grid, track start or hotcue 1), track end warning (seconds, 0 = off), load lock while a deck plays
* tempo & sync: keylock on for the first load, default tempo range (±6 … ±100 %), phase lock while synced, sync mode (dynamic / fixed / tempo only), pitch bend amount, link offset (ms)
* loops & beatjump: default loop size and beatjump size, loop snap (only with snap on) to loop cues (on, window 1-8 beats, default 4) and to the 4-bar grid (on, tolerance 1-8 beats, default 1), active loop every pass / once per load
* rows per deck (`ui.deckRows`), compact decks
* master clock & metronome: metronome output pair
* phrase anchor: off / suggest (default) / automatic -> on load the anchor is checked against the track's 8-bar structure, see manual 05
* edit mode & tool-loops: snap when marking (`ui.editSnap`: 1 beat / 1 bar / 2 / 4 / 8 bars, default 1 bar), load the cut result into the deck (`ui.cutLoadsResult`), tool-loops into folder … (`ui.toolLoopFolder`, empty = next to the original), prepare amp: allow clipping (`ui.prepAllowClipping`, off), prepare join: match tempo within ±0.5 % (`ui.prepJoinMatchTempo`, on) -> [manual](MANUAL.md#prepare-mode)
* groove → midi (`groove`): midi source name (default `MINOS-741 Groove`), channel bass (1) / drums (10), bass octave 0-3 (C3 = 60, default 1), length without loop 1 / 2 bars (default 2), offset −100…100 ms. instrument and style of the deck row are saved here too

## ◆ MIXER & FX

* mixer: show internal mixer, auto-gain from the collection loudness, headroom internal (−3 dB default)
* mixer options: eq kill (knob fully left = off), crossfader curve (smooth / sharp cut), channel filter resonance
* external mixer: headroom, auto-gain, main volume also external
* fx units: show, 2 or 4 units, delay feedback, fx filter resonance, reverb type, reverb level (dB, 0 = reverb ~4 dB below the track at full d/w), reverb brightness (dark -> airy: high decay 35 … 90 %, low cut 150 … 400 Hz, high shelf −4 … +6 dB, default 0.6), reverb pre-delay (ms)
* fx mapping: per unit D/W, knob 1-3, button 1-3 -> parameter of the loaded effect (menu, search field above), all to default. same menu as the right click on the unit
* remembered mappings per effect / plugin id / plugin chain (`engine.fxMappings`, chain key = plugin ids joined by ` > `), forget per entry. a unit keeps its own mapping in the session
* remembered plugin chains (`engine.pluginChains`: name -> slots with plugin id, on / off, state), forget per entry. saved from the chain popover of a unit or the master bus

## ◆ PLUGINS

saved as json in `~/Library/Application Support/MINOS-741/plugins.json`, not in the user defaults.

* load third-party plugins isolated (on): separate system service for audio units, apple plugins and VST3 always in-process
* folders: system and user audio unit folders + AUv3 + system and user VST3 folders (always), own folders (add / remove), install plugin … (`.component` and `.vst3`), rescan
* list with search: per plugin use in MINOS-741 (on / off), status, PRÜFEN (auval / VST3 self-check), click -> path, load default / isolated / in-process (audio units), `läuft im prozess` (VST3), unblock, last log
* ALLE PRÜFEN with progress and cancel, results kept per plugin + version
* crash marker `plugin-opening.json` next to it, a leftover marker blocks that plugin on the next start -> [manual](MANUAL.md#-08--fx)
* chains (up to 4 per fx unit, master bus) use the same list, isolation and crash handling per slot: a crashed or hanging slot is passed through, reloads after 2 s, blocked after 3 crashes
* offscreen image of this tab without audio: `MIX741_SELFTEST=1 MIX741_SHOT=plugins:<folder>` (optional `MIX741_SHOT_PLUGINS=<plugin folder>`)

## ◆ BROWSER

* rows: padding around the text 3-16 pt, line between rows, height snaps to whole rows
* played tracks: dim (on), hide (`ui.hidePlayedTracks`, off; also `UNGESPIELT` in the pane header, browser menu, assignable key `browser.hideplayed`), reset on start (off). hidden in collection, playlists, smartlists, music folders, search; not in history, running tracks, preparation (+ archive) -> [manual](MANUAL.md#-09--browser)
* history & preparation: played after x seconds audible (`engine.historyThreshold`), optional copy into the collection's history folder
* preview: start position of the browser preview (share of the track)
* harmony to the master: color the key column (on) -> [manual](MANUAL.md#harmony--matching)
* ◆ PASST (matching): which steps count besides the same key: ±1 on the wheel (on), relative major / minor (on), energy ±2 (off). bpm window ±1-10 % (±4), half / double tempo (off). `ui.harmonyColors`, `ui.match`
* browser preview: full row, two lines (default) / own column / behind the title / off; colors spectrum red / green / blue (default) / like the waveform; compute in the background: always, throttled while a deck plays (default) / only while no deck plays / off -> [manual](MANUAL.md#preview)
* cover: in the deck header (on), preview of the selected track below the browser tree (on). the browser column `Cover` is switched via right click on the list header
* collection: music folders for MUSIC FOLDERS (add / remove, empty = automatic: the folder holding 90 % of the collection's files); write browser edits into the collection file (off): backup at most once per hour into `Backup MINOS-741`, not while the library software runs -> [manual](MANUAL.md#write-into-the-collection-file)
  * with it: cuts and tool loops as new entries (on), preparation + own history + own folders / playlists as playlists in `MINOS-741` (on)
* check collection: on start (off), scan the music folders for files without a collection entry (on) -> [manual](MANUAL.md#check-the-collection)
* analyse: bpm range (one octave, default 100-200), learn / discard key profiles
* DAW bridge: receive warp markers and position from the DAW's remote script (on), udp port 7411 (127.0.0.1 only). `ui.dawBridge`, `ui.dawBridgePort` -> [manual](MANUAL.md#grid-from-the-daw-live-bridge)

## ◆ TAGS

* separator for comment 2 (`ui.tagSeparators`, empty = space), color tags (`ui.tagHighlight`)
* tag colors: every tag of the collection by count (filter, first 300), color per tag (`ui.tagColors`), ↺ = default color

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
* cue action: flux reverse / cue / reverse
* flux button: switch pad layer (hotcues 5-8, default; shift + flux = flux mode) / flux mode (tap toggles flux mode if enabled)
* flux held + pads: hotcues 5-8 or beatjump on pads 3 / 4, beatjump size for flux + hotcue 3 / 4
* touch strip: bend or seek, sensitivity
* browse step with shift, shift + LOAD, browse push: big browser (default) / matching on / off
* leds: brightness on / off, startup show on connect (on). pad colors = cue colors under DISPLAY
