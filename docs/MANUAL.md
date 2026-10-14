# MANUAL

```
> minos --manual
  01 install          06 sync / clock / link   11 history + preparation
  02 first start      07 mixer + audio          12 keys
  03 screen           08 fx                     13 files + folders
  04 decks            09 browser                14 troubleshooting
  05 waveform + grid  10 tags + smartlists      15 faq
```

user manual for MINOS-741 `0.7.x`. ui terms are shown in CAPS like on screen.
reference pages: [docs index](README.md).

---

## ◆ 01 · INSTALL

needs macos 15+, apple silicon or intel.

**homebrew**

```
brew install --cask slayer7411/tap/minos-741
```

update: `brew upgrade --cask --greedy minos-741`

**dmg**

1. [releases](https://github.com/Slayer7411/MINOS-741/releases/latest) -> `MINOS-741.dmg`
2. open it, drag MINOS-741 onto APPLICATIONS
3. first start: macos blocks it (not signed by apple) -> system settings -> privacy & security -> OPEN ANYWAY

update: download the new dmg, replace the app.

**from source** (xcode / swift 6)

```
git clone https://github.com/Slayer7411/MINOS-741.git
cd MINOS-741
scripts/make-app.sh
```

-> builds `MINOS-741.app`, signs it locally and installs it to `/Applications`.
`scripts/make-app.sh --no-install` keeps it in `build/`.
dev run without bundle: `swift run minos741`.

update from source:

```
git pull
scripts/make-app.sh
```

settings, session and history survive updates.

## ◆ 02 · FIRST START

1. close other dj software (the controller can only talk to one app)
2. start MINOS-741 -> it loads the newest `collection.nml` from your library folder
   other collection -> ⌘O
3. ⌘, -> AUDIO -> pick the output device and the mode
   * INTERNAL -> mixer in the app, master on one pair
   * EXTERNAL -> every deck on its own usb pair into your desk
4. ⌘, -> CONTROLLER -> check which controller drives which decks, BLINK shows the unit. the side (left a / c, right b / d) is saved per device serial number, the startup show displays it on connect
5. double click a track = load into the focused deck (⌘1-4), right click -> load into deck A-D, or LOAD on the controller

nothing is analyzed. bpm, key, grid, cues and loudness come from the collection.
tracks without an analysis in the collection play, but have no grid -> no sync. right click -> `Analysieren` computes tempo, grid, key and loudness in MINOS-741 (see [analyze](#analyze)).

## ◆ 03 · SCREEN

```
┌ toolbar ─ PROFILE ▾ ───── MIXER · 1 / 2 / 4 · browser layout · DECKS · ↻ ┐
├ FX 1 ─────────┬ master clock + link + metronome ─┬ bars ──┬ FX 2 ─┤
├ deck A ───────────────────────┬ deck B ────────────────────────────┤
├ deck C ───────────────────────┼ deck D ────────────────────────────┤
├ browser pane 1 ───────────────┼ browser pane 2 ────────────────────┤
└ status: message · detail ─ device · routing · prep ─ DSP LAT DROP RAM CPU ┘
```

* PROFILE ▾ (left) -> view profile, see [view profiles](#view-profiles)
* MIXER -> internal mixer on / off (⌥⌘M)
* 1 / 2 / 4 -> decks shown. 1 = deck A over the full width (mixer next to it when on), 2 = A + B, 4 = A-D. hidden decks keep playing. ⌥⌘4 switches 2 ↔ 4 (from 1 -> 4)
* browser layout -> one pane, side by side, stacked
* DECKS -> hide decks, big browser (⌥⌘B)
* ↻ -> reload the collection
* the line between decks and browser can be dragged, the height is saved
* fullscreen -> toolbar hides, comes back with the mouse at the top
* zoom like a web browser -> ⌘+ / ⌘− / ⌘0 (view menu), 50 · 67 · 75 · 80 · 90 · 100 · 110 · 125 · 150 · 175 · 200 %, step shown in the status bar, saved. text, controls, waveform marks and table columns scale at full resolution. minimum window size × zoom, capped at what fits the screen. toolbar, settings and dialogs stay at 100 %

### view profiles

a profile = named set of view settings: decks shown (1 / 2 / 4), internal mixer, fx units on / off and count, deck rows (incl. grid tools, so also compact decks), browser layout, browser height, hide tree, big browser, status bar, load meters, waveform minimum height, cover in the deck, cover preview, browser preview mode. not in it: audio, controller, waveform style and colors, tags, keys.

* switch: PROFILE ▾ left in the toolbar, view menu -> profile, ⌃⌥⌘1-4 (first four of the list), ⌃⌥⇥ next profile. keys assignable under ⌘, -> KEYBOARD
* switching only sets these fields, decks are rebuilt only as far as the toolbar switches do it anyway
* after a switch any view change keeps the name, marked `*` (`Default Setup *`) until `update profile`
* `save current view as profile …` asks for a name, an existing name is overwritten. `update profile` -> active profile = current view. `delete profile …` asks first
* ⌘, -> DISPLAY -> profiles: rename in place, APPLY, UPDATE, ↑ / ↓ order (first four = keys), ✕ delete, SAVE CURRENT VIEW
* first start with this version: `Default Setup` (4 decks, no internal mixer, no fx units, rows readouts + phase bar + transport + loop, browser side by side, status bar automatic, no cover in the deck) and `Musik suchen` (english `Search music`: 1 deck, no mixer, browser ≥ 520 pt with tree, preview full row, cover preview, status bar always). other values from the view saved before. deleted profiles stay deleted
* saved in `prefs.v1` -> `ui.layoutProfiles`, active one in `ui.activeLayoutProfile`

### status bar

* ⌘, -> DISPLAY -> status bar (also view menu): `always` / `automatic` / `off`. automatic: the bar slides up over the browser when the mouse sits at the bottom edge of the window or a warning / error arrives (6 s), gone when the mouse leaves it. off: no bar, no messages
* left: current message, second line = path / reason or progress (`42/120`, ✕ = cancel). idle: tracks · collection · load time
* colors: red = error, gold = warning, purple = info, bone = done
* info 4 s, done 3 s, warning 8 s, error stays until clicked or replaced. `+n` = more active messages
* click -> last 50 messages with time
* messages: track load failed / timed out, track loaded, phrase anchor found, plugin not loaded / blocked, collection loaded, collection file written / not written, metadata saved, export progress / done, played state reset, zoom step
* middle: device · mode · routing · rate, ↻ reconnect, preparation count, preview progress
* right (⌘, -> DISPLAY -> status bar):

| meter | shows |
|---|---|
| DSP | render time of one audio block ÷ block duration, bar = average, tick = peak (held 1.5 s), red above 70 % |
| LATENCY | output latency in ms (buffer + device + safety offset + stream), buffer frames · device rate |
| DROPOUTS | blocks over 100 % of their budget + overload reports from the device, since start. red = one in the last minute, click = reset |
| RAM | memory of the process (physical footprint) |
| CPU | process cpu, 100 % = one core |

click on the meters -> details (keylock lookahead, own vs device overloads).

## ◆ 04 · DECKS

### header

```
A ▣ title                FX1 FX2    -1:10  130.00    5/16   11m   ±8 ▾
    artist                           33.2  +0.00%  ◆ CODE
    peak dark vocal  comment …
```

* deck letter turns red while playing
* line under the title: tags from comment 2 as chips (colors + separators like the browser, ⌘, -> TAGS), then comment in grey. one line, too long -> `…`. fixed height, also without a track. off: DECKS -> ROWS
* ▣ cover of the loaded track (embedded in the file, else `cover` / `folder` / `front` .jpg / .png in its folder), `◆` = no cover. off: ⌘, -> DISPLAY -> cover
* FX1 / FX2 (… FX4) -> deck on that fx unit
* code readout: bar of the track in its phrase (`5/16`, phrase start = grid anchor, length = waveform phrase, ⌘, -> DISPLAY) against the bar counter. purple `◆ CODE` -> same bar and beat as the counter, red `+2 BARS` / `−3 BEATS` -> the deck is that far ahead / behind (wrapped to half a phrase), grey -> deck stopped or no counter
* remaining time, bpm, tempo offset, key readout: open key of the track (e.g. `11m`), next to it the audible key in red as soon as it deviates (`11m → 6m`), below the deviation in semitones (`+0.60`). keylock off -> the tempo detunes, keylock on -> only the key shift counts
* `±8 ▾` -> tempo range ±6 / 8 / 10 / 16 / 50 / 100 %
* KEY SYNC -> key shift so the audible key fits the master's audible key: same key, relative or neighbour on the open key wheel, smallest shift, at most ±6. keylock off -> on. result in the status bar (`Deck B: Key-Shift -3 -> 4m (Master 4d)`). needs a key on both tracks and another deck as master

### rows

DECKS -> ROWS or ⌘, -> DECKS -> rows per deck, each on / off: readouts, comment, tags (comment 2), phase bar, overview, transport, hotcues (with IN / OUT / RE), loop sizes, beatjump, grid tools, pitch fader. waveform and header always stay.

* pitch fader off -> waveform and rows take its width
* DECKS -> compact decks (⌥⌘K) -> pitch fader, hotcues and grid tools off / on together -> more room for waveform and beatgrid
* hidden rows keep working from keys and controller

### transport

| button | action |
|---|---|
| CUP | jump to cue, play on release |
| CUE | stopped: set cue / hold = preview. playing: back to cue |
| ▶ | play / pause |
| SYNC | follow the master (tempo + phase) |
| MASTER | make this deck the tempo master |
| KEY | keylock (tempo changes keep the pitch) |
| − / + | key shift ±1 semitone (±12) |
| REV | reverse |
| FLUX | flux mode: loops, jumps and reverse continue in the background, release -> back where the track would be |
| DBL | instant double: track, position, tempo, keylock, key shift, sync, loop, cues and cut of the neighbour deck (A↔B, C↔D), plays along in sync. right click -> any deck, ⌥-click -> even if this deck plays |
| EDIT | edit mode: cut row instead of the loop sizes, grid row, handles in the waveform ([edit mode](#edit-mode)) |

### cues + loops

| button | action |
|---|---|
| 1-8 | hotcue: click = jump / set, ⌥-click = delete, right click -> active loop / delete |
| IN / OUT | manual loop |
| RE | reloop |
| LOOP | auto loop on / off with the selected size |
| 1/32 … 32 | loop size. click = select, a running loop takes the new size |
| ◀◀ 1/4 … 64 ▶▶ | beatjump size + jump. inside a loop = jump by the loop length, the loop moves along (nothing to hear) |

* hotcues, loop sizes and beatjump sizes each span the full deck width
* the selected loop size is purple, the selected beatjump size red, also when changed from the controller (loop encoder, flux + pads)

* hotcues come from the collection. colors: start cue red, cues white, loops green, short loops magenta (⌘, -> DISPLAY)
* edits are saved in an own file. the collection stays untouched
* SNAP -> cues and loop points lock to the beat
* loop snap (with SNAP, LOOP / LOOP IN from deck, keyboard or controller):
  1. a stored loop cue (hotcue or memory cue) starting up to 1 bar ahead or just passed (playhead still inside it) -> exactly that loop, start and length
  2. otherwise within 1 beat of a 4-bar boundary (counted from the grid anchor) -> the loop starts on that boundary
  3. otherwise the normal beat snap
  * no jump: the playhead runs into the loop or is already inside. both rules and windows under ⌘, -> DECKS -> loops & beatjump
* QUANT -> jumps keep the beat phase
* active loop: right click a loop hotcue -> `Active Loop`. dot on the button (`3 •`), dashed frame in the waveform. the playhead reaches the loop start (forward, no other loop on) -> the loop engages, no jump. LOOP leaves it, the next pass engages again. ⌘, -> DECKS -> loops & beatjump -> every pass / once per load. saved per track with the own edits

### tempo

* fader on the right: drag = tempo, double click = 0
* ‹ › -> pitch bend while held
* 0 -> tempo back to 0 %
* synced decks can't be moved by hand, only the master

### load

* double click = focused deck, right click -> load into deck A-D, controller LOAD = selected track of its own pane
* load lock (⌘, -> DECKS, on by default): a playing deck (also cue held) takes no track -> `Deck B spielt · Laden gesperrt` in the status bar. force: ⌥-double click, shift + LOAD on the controller, key `load selection (even if playing)`
* instant double (DBL, key, shift + LOAD if set): no load, the deck shares the audio of the source and takes its audible position at the next audio block, sample exact. counts once in the history
* jumps to load cue / grid, track start or hotcue 1 (⌘, -> DECKS), inside the cut if the track has one
* first load: keylock on (setting)
* track end warning: remaining time blinks red x seconds before the end (0 = off). remaining time and warning count to the cut end
* file missing -> fails at once. no audio data for 4 s (cloud file not downloaded, read stuck, setting 2-15 s) -> load cancelled. unreadable format -> fails with the reason
* failed load: deck empty, reason in red in the header, skull in the waveform for 5 s, message in the status bar. other decks are never touched
* empty deck -> lobster in the waveform

### undo

* ⌘Z = undo the last edit, ⇧⌘Z = redo. edit menu names the next step (`undo: set hotcue 3 · deck B`), the status bar what was undone. keys assignable (⌘, -> KEYBOARD)
* deck: hotcue set / delete, active loop, loop on / off / size / in / out / reloop / from range, beatjump and jumps via overview or waveform drag (play head moves back by the jump, a playing deck keeps running), grid (anchor, move, bpm, tap, reset, phrase anchor), cut in / out / clear / from range, marked range, key shift, key sync, keylock, tempo, sync, master, flux. own edits (hotcues, grid, cut) are saved again after undo
* browser: append to / remove from preparation, reset played state, metadata from the edit window and inline edit (written back the same way, also into the collection file when that is on)
* not undone: track load, instant double, unload (they clear that deck's steps), play / pause / cue, hotcue jump, mixer and fx, settings, cut audio (the new file stays), tag colors
* a drag (tempo fader, waveform, overview, cut handle, range) or quick repeats (grid nudge, tap) = one step
* up to 100 steps, gone on quit. inside a text field ⌘Z stays text undo
* controller actions are not recorded

## ◆ 05 · WAVEFORM + GRID

* rendered as bitmap tiles in screen resolution (background thread) -> sharp at any zoom, no load on the render server
* height = real file level, full height = 0 dBFS, no normalizing -> loud masters look loud
* styles (⌘, -> DISPLAY): 3-band blend (default) / spectrum (6 bands) / mono, palettes (not for spectrum): spectrum (rgb, default) / 741 bone / orange / blue / classic
* 3-band blend: each pixel row colored by the bass (< 150 Hz), mids (around 670 Hz) and highs (> 3 kHz) of the samples that reach it, brightness = share of samples reaching the row ^(1/3.5). the three bands of a block are stacked by their peak: the strongest is the body from the centre, the weakest sits outside at the tips -> bass red core, mids yellow / green ring, hats blue edge, soft upper edge. highs take the held share of the spectrum analysis: short highs (closed hats) blue, held highs (open hats, ride, noise) light blue (741 palettes: high color half way to white). lows: a kick rises above the low level of the last 300 ms -> red, fading to orange as it rings out; a bass line or the sub tail sits on that level -> orange (741 palettes: low color half way to orange). no kick = no red hits. `variant` A-K switches the mix (mids, stacks vs energy mix, edges, orange) for comparison, A is the default. spectrum (rgb): bass red, mids green, highs blue, mixes yellow / cyan / white. overview in the same style. `high emphasis` 0-3 -> high weight ×0.5-×4 (color and stack height)
* drag the waveform = scrub, click the overview = jump
* played part can be dimmed

spectrum (6 bands), colors:

| color | band | what it shows |
|---|---|---|
| orange | sub 20-60 Hz | sub bass, kick tail |
| red | bass 60-250 Hz | kick body, bass line |
| green | low mids 250 Hz-1 kHz | synths, vocals, chords |
| yellow-green | high mids 1-4 kHz | leads, snare / clap body |
| blue | highs 4-10 kHz, short | closed hats, shakers |
| light blue, brighter | highs + air, held | open hats, ride, noise, risers |

* each block (3.3 ms) takes the color of the band that is loudest against its own level in this track -> a kick reads red / orange, the hat between two kicks blue, an open hat light blue
* highs also run as a layer in the middle (height = how strong the highs are) -> hats stay visible on top of kick and bass, also zoomed out
* closed vs open: share of a ~150 ms window in which the highs stay within 8 dB of their peak. short spikes = closed, held = open
* `high emphasis` (⌘, -> DISPLAY): 0 = neutral, 1 = default (+5 dB for highs in the mix), 3 = +15 dB
* analysis runs while the track loads, parallel to the waveform blocks: ~0.1 s cpu per 8-minute track on a second core, ~0.03 s longer load. 8 bytes per block, ~1.4 mb per 10 minutes

beatgrid:

* thin beat lines, stronger bar lines with caps top and bottom, bar numbers on the ruler
* loop: red frame + tint, cues: line in their color + numbered flag, play head red
* phrases (16 / 32 / 64 / 128 beats) in purple, phrase countdown at the play head (`P3 · 16 T`)
* magenta markers every 8 / 16 / 32 bars (setting)

grid row (`GRID`):

| button | action |
|---|---|
| ◂◂ ◂ ▸ ▸▸ | move the grid 10 / 1 ms |
| BPM − / + | ±0.01 bpm |
| ÷2 ×2 | half / double bpm |
| TAP | tap on the beats -> bpm from 4 taps on (pause > 2 s starts over), anchor stays |
| SET | beat 1 at the play position |
| RESET | grid from the library (collection or own analysis), the own grid edit is removed |
| ◂4 ◂1 1▸ 4▸ | anchor 1 bar / 1 beat earlier or later -> grid lines and bpm stay, only bars and phrases are renumbered |
| PHRASE +n | (red, only with a suggestion) move the anchor by the suggested beats |

narrow decks show fewer anchor buttons (◂1 1▸, then only `PHR +n`).

phrase anchor:

* the collection anchor often sits on the first audible hit -> a cut first hit or a pickup beat shifts bars and 8-bar phrases by 1-3 beats, the code readout and phrase lines are off
* on load the track is checked in the background (~0.1 s after decoding): spectrum per beat (13 bands) -> change curve over 1 / 2 / 4 bars -> structural changes (elements in / out, breakdown, drop) -> the anchor shift in whole beats (−15 … +16) that puts most of them on 8-bar boundaries, 4-bar and bar boundaries count less
* no clear evidence -> no change (confidence < 0.3, fewer than 4 changes or fewer than 3 on phrase boundaries)
* setting `align grid anchor to phrases`: off / suggest (default, red `PHRASE +n` in the grid row) / automatic (anchor moves on load, `MIX741_DEBUG=1` logs `[phrase] deck n: anchor +k beats (conf x)`)
* stored like every grid edit in minos's own edits (`edits.json`), never in the collection; bpm and grid lines stay. the start cue stays at the collection anchor

grid edits:

* every change in the grid row (also an automatic phrase anchor) is an own grid: bpm + anchor saved per track in `edits.json`, laid over collection and own analysis on every load
* `Analysieren` / `Neu analysieren` never replace it, only RESET does
* shown in red: `GRID` label, anchor flag `G` in the waveform, `◆` before the tempo in the header

### edit mode

`EDIT` in the transport row, ⌥⌘E (focused deck) or menu DECKS. per deck, saved in the settings, off by default.

* the cut row takes the place of the loop sizes, the grid row is shown (in place of beatjump when the grid row is off). the waveform keeps its height, switching only swaps the rows (~10 ms)
* cut = play only a part of the file, e.g. without the stray kick of the next track at the start or the end. the audio file is never changed (also on cloud drives)

| button | action |
|---|---|
| IN HERE | cut start at the play position, on the nearest beat with QUANT, ⌥-click = exact |
| OUT HERE | cut end at the play position, same snapping |
| CLEAR CUT | whole file again |
| `0:01.0 → 4:50.0 · 4:49.0` | start → end · length, grey = file start / end |

* waveform: outside the cut dimmed, in edit mode handles `IN` / `OUT` -> drag (snaps like IN HERE, ⌥ = free). overview: same, drag a handle or click to jump
* without a cut the handles sit at the file start and end
* shortest cut 1 s, else message `Schnitt zu kurz`
* playback stays inside: nothing outside is audible (3 ms ramp at a cut edge), jumps, seeks, cue, CUP, hotcues land inside, forward play stops at the cut end like at the track end, reverse stops at the cut start, a loop over the cut end is shortened to it, a beatjump past the end lands on the last whole beat before it
* cut start / end saved per track in `edits.json` (seconds), with the grid edits. a cut is never written into the collection
* browser `Vorhören` plays only the cut (from the preview start share of the cut, stops at the cut end), a cut changed on a deck moves a running preview of the same track. browser preview: outside the cut dimmed, edges marked (not draggable)

### cut audio

real cut = a new audio file. the original is never changed.

* ⌃ + drag in the waveform = mark a range, start and end on the nearest beat of the grid, ⌃⌥ = free. red tint, edges with tabs, label `bar.beat → bar.beat · beats B · seconds`, also in the overview
* drag an edge = move it (same snapping, ⌥ = free). the range stays until esc, a click outside it, a new range or another track
* right click in the range:

| entry | action |
|---|---|
| Bereich entfernen (neue Datei) | new file without the range (breakdown out) |
| Auf Bereich kürzen (neue Datei) | new file with only the range |
| Ergebnis ins Deck laden | on: the new file loads into the same deck (load lock applies: a playing deck keeps its track). also in menu DECKS |
| Schnitt IN/OUT aus Bereich | cut start / end = range, no file |
| Loop aus Bereich | loop on the range, play head jumps in when outside |
| Bereich aufheben | range off |

* edit mode: with a range the cut row shows `REMOVE` / `KEEP` / `→ CUT` / `→ LOOP` / `✕` (narrow decks: REMOVE / KEEP / ✕)
* keys (⌘, -> KEYBOARD, no default): remove range, keep range, cut in / out from range, loop from range. esc = clear range (only taken when a range exists)
* file: `<name> [cut].m4a` next to the original, apple lossless, sample rate and channels of the original, 16 bit from 16-bit sources, else 24. name taken -> `[cut 2]`, `[cut 3]` …
* 2 ms linear crossfade at the joint, 2 ms fade at an edge inside the track (keep). length = original minus range (remove) or range (keep), sample exact
* source: decoded audio of the deck when it has the file's rate, else the file is decoded again at its own rate. runs on an own queue (not main, not audio thread), progress + ✕ in the status bar, then `Geschnitten: <file> · 5:12`
* metadata: all fields of the original, title + ` [cut]`, bpm, key, comments, tags (comment 2), cover of the original. grid: anchor before the removed range stays, else it moves back by the removed length. keep: anchor from the new start, by whole bars behind it when it would lie before. hotcues, memory cues and loops outside the removed part move along, inside are dropped (loops over a cut edge too). a grid marker on a hotcue slot stays there on the new anchor
* browser: tree entry CUTS (once a cut exists) with all cuts and their metadata, the file in MUSIC FOLDERS shows the same. saved in `cuts.json`, never in the collection file. `Collection prüfen` lists a cut in a music folder like any file without an entry

## ◆ 06 · SYNC / CLOCK / LINK

```
LINK 1 │ AUTO  128.00  − +  SEMI │ TICK ◯ │ S │ MAIN ◯ ⚙
       │ MASTER  DECK B  TAP      │        │ Q │
```

* AUTO -> a deck is master (automatic or via MASTER on the deck). the automatic master stays as long as it plays: a deck you start or load later does not take it over
* MASTER -> the clock is master, all synced decks follow it
* SEMI -> semi-sync: every newly loaded track takes the tempo of the current master (clock or master deck, half / double tempo picks the nearest ratio), no phase lock. the tempo range grows to the next step if needed. an unsynced deck starts in phase with the running master (play, cup, cue): one jump to the nearest beat at start, then it runs free, tempo untouched
* tempo: drag the number or − / +, TAP = tap tempo
* TICK -> metronome on the clock beat, own volume, own output pair (setting)
* S = snap, Q = quant
* MAIN -> main volume. hidden in external mode unless `main volume also in external mode` (⌘, -> MIXER & FX)

sync modes (⌘, -> DECKS):

* DYNAMIC -> tempo + phase, always pulls back to phase 0
* FIXED -> a shifted phase stays shifted
* TEMPO ONLY -> no phase lock

phase lock runs on its own thread: tempo every tick, phase via a small rate nudge, hard jump only if the error stays > 0.25 beats.

link (network tempo sync):

* LINK -> join the link session, the number = peers
* minos leads tempo and bar, the other apps follow
* link beat is time stamped in the audio callback -> no drift
* offset setting for latency between the two apps

bar counter (top right): runs from the first play, 4 / 8 / 16 bars, the big number counts within the phrase (⌘, -> DISPLAY, default 16 bars) and starts over, double click or ↺ = back to bar 1. next to it the time of day and a stopwatch (from the first play, click = restart at 0). the whole top bar scales 60-130 % by dragging the grip below it (double click = 100 %), fx units sit 10 pt flatter. bar 1 of the counter = bar 1 of a phrase (the code). each deck header shows `◆ CODE` or how far the deck is off (`+2 BARS`) -> a beatjump of that size the other way brings it back in.

## ◆ 07 · MIXER + AUDIO

### internal mode

per channel (order C · A · B · D):

* gain + auto-gain (loudness from the collection)
* eq hi / mid / lo, knob fully left = kill (setting)
* one-knob filter: left = low pass, right = high pass
* fx assign, channel fader, crossfader assign + curve (smooth / sharp)
* headroom per mode (internal default −3 dB)
* no limiter on purpose, hard clip as last stage

### external mode

* every deck on its own pair, default A 1/2 · B 3/4 · C 5/6 · D 7/8
* gain / eq / fader happen on your desk
* own headroom and auto-gain setting, main volume off by default
* metronome on an own pair

### preview output

* browser `Vorhören` plays in the audio core on an own pair of the same device, never on the macos default output
* ⌘, -> AUDIO -> preview: `Automatisch` (default) · any pair · `Aus`
  * external: first pair after the highest deck pair that no deck uses (12 outputs, decks on 1/2 … 7/8 -> 9/10). none free -> off. a deck pair only by hand
  * internal: main output, added after main (main volume does not touch it)
* on the desk: set a free channel's input to that usb pair, fader down, cue on -> preview only in the headphones
* pair not on the device (other interface) -> silent, never another pair
* preview volume in the same section. own volume, no eq / fx / keylock
* loads like a deck through the file service (cache hit ~0.01 s, first load = decode time), status bar `Vorhören lädt …`, a new track cancels the running load

routing is in ⌘, -> AUDIO. the device sample rate is never changed by minos.
the status bar shows device, mode and routing, preview pair as `PRE→9/10` (`PRE→–` = off).

### device gone, rate change, sleep

* interface unplugged or off -> output stops, status bar `Warte auf <device> …`, the decks keep their state. same device back (same uid) -> output reopens by itself (self test: ~5-12 ms after the device shows up), notice with the gap
* no fallback to the built-in speakers while minos waits for the chosen device. ↻ / ⌘, -> AUDIO -> reconnect still works by hand
* rate changed in audio midi setup -> output reopens on the new rate, the core keeps its rate (resampled), notice. buffer changed from outside -> latency re-read
* while the output runs: no app nap, no idle sleep (`pmset -g assertions` -> `MINOS-741 audio output`)
* mac goes to sleep -> output stopped before, reopened after wake, playing decks play on. controllers are reconnected after wake
* counters: click the meters -> `Gerät neu verbunden`, `Raten-/Pufferwechsel am Gerät`

## ◆ 08 · FX

2 or 4 units (⌘, -> MIXER & FX). each unit:

* GRP -> group mode: 3 slots at once, D/W + one knob + ON each. default FILTER · DELAY · REVERB, slot menu (`FLT·DLY·REV`) -> any built-in effect per slot, each once (picking one already in another slot swaps them)
* SNGL -> single mode: one effect, 3 parameters
* delay time in beats (`1 ▾`), beat synced to the deck tempo
* reverb type -> ⌘, -> MIXER & FX: `Reverb` (default, allpass ring: dense, darker tail, 0.4-7 s) or `Reverb (FDN)` (long, airy)
* ROOM -> reverb size. `Reverb`: 0 small room (0.4 s) · 0.5 (1.6 s) · 0.6 default (2 s) · 0.9 (5 s) · 1 (7 s). `Reverb (FDN)`: 0 (0.3 s) · 0.5 (3.6 s) · 0.6 (5.6 s) · 0.9 (22 s) · 1 near freeze (~3 min)
* FRZ -> reverb freeze (single REVERB: button 2, group: assignable): input closed, the tail stands until FRZ off, the track keeps playing
* reverb level, brightness, pre-delay -> ⌘, -> MIXER & FX. level 0 dB: full d/w adds the reverb ~4 dB below the track, same in group and single mode
* brightness -> how long the highs ring: 0 dark, 0.6 default (airy hiss in the tail), 1 bright. below ~150-400 Hz nothing goes into the reverb
* washes / exits: size 0.8-1, reverb on, reverb off or deck stop -> the tail keeps ringing (spillover)
* deck assign: FX1 … FX4 in the deck header or the mixer
* default: FX1 -> A / C, FX2 -> B / D

effects so far: filter, delay, reverb, gater, roll, flanger, phaser, PLUGIN. more -> [roadmap](roadmap.md).

### BEAT FX

grid = master clock (follows the master deck's tempo and phase). switching on waits for the next divider, rate / length in beats.

| effect | knob 1 · 2 · 3 | button 2 · 3 | group knob |
|---|---|---|---|
| GATER | RATE 1/16-1/2 · SHAPE (square -> decay) · WIDTH (open part) | MUTE · TRIP (×2/3) | depth |
| ROLL | LEN 1/32-1 · FILTER · DECAY (0 to -24 dB per beat) | REV | length |
| FLANGER | RATE 1/2-32 beats (SYNC off: 0.02-4 Hz) · DEPTH · FEEDB | FRZ (lfo stands) · SYNC | amount |
| PHASER | RATE 1/2-32 beats (SYNC off: 0.02-4 Hz) · DEPTH · FEEDB | FRZ · STAGE 4 / 8 | amount |

* button 1 = on / off, D/W = share of the effect, D/W 0 = dry signal untouched
* ROLL repeats the last length from the divider on, the deck keeps running underneath (like flux): off -> back where the track is now. shorter length while rolling -> start of the take on the same grid, longer -> new take at the next divider
* flanger 0.3-8 ms, stereo phase assignable (default 90°). phaser 130 Hz-6.2 kHz, l/r 90°
* group: rate, mute, trip, rev, freeze, sync, stages assignable per slot, same values as in single mode. on / off ramps 5 ms

### MAPPING

D/W, knobs 1-3 and buttons 1-3 of every unit sit on any parameter of the loaded effect. the controller uses the same mapping.

* right click a knob or button -> `Standard` (default) · `Nicht zugewiesen` (off) · every parameter of the effect
* built-in effects -> their own parameters. group: amounts, on / off, delay time, room size · single: the 3 parameters, on / off, d/w
* audio unit / VST3 -> the full parameter list with unit and range, in the plugin's groups, long lists in submenus of 20. D/W lists mix / wet / dry parameters first
* buttons: switch -> toggles, list -> next entry (wraps), continuous -> min / max
* label under a knob = short parameter name, bright = own mapping. hover, drag or turn -> value with unit (VST3: text from the plugin)
* the unit's D/W only acts while a control sits on it. D/W on the plugin's mix -> the unit runs fully wet
* remembered per effect (`GROUP` or `GROUP:FILTER/GATER/REVERB` per slot set, `FILTER`, `DELAY`, `REVERB`, `GATER`, `ROLL`, `FLANGER`, `PHASER`) or plugin id -> the same effect loads with its mapping again, on any unit
* the session keeps each unit's mapping and the values of mapped plugin parameters
* table per unit with search, remembered mappings with forget -> ⌘, -> MIXER & FX
* default = the layout below: group = amount + on / off per slot, single = 3 parameters + button 1 on / off, plugin = first three parameters

### PLUGIN

any installed audio unit effect (apple or third-party, v2 and v3) or VST3 effect in the single mode, e.g. AUMatrixReverb or AUReverb2 instead of the built-in reverb.

* SNGL -> effect menu -> PLUGIN -> the menu below lists every installed effect (`name · manufacturer`, VST3 with a small `VST3` behind)
* knobs 1-3 -> the first three parameters of the plugin (default), labels from the plugin. any parameter -> [mapping](#mapping)
* D/W -> dry / wet of the unit (on top of the plugin's own mix), or mapped to the plugin's mix
* ON -> on / off. off = spillover: the plugin gets no new audio and rings out
* EDIT -> window with the plugin's own view (or a generic one) · changes go to every deck on that unit
* one instance per deck · loads in the background, the deck plays on dry meanwhile
* plugin and its settings are saved with the session
* newly installed plugins -> menu -> rescan plugin list (the PLUGINS tab rescans on its own)
* the menu lists only plugins that are enabled and not blocked -> ⌘, -> PLUGINS

### manage plugins (⌘, -> PLUGINS)

* list of every effect plugin: name, manufacturer, version, AUv2 / AUv3 / VST3, source (system / user / own folder / app), status, search field
* square left = use in MINOS-741. off -> not in the fx menu (a loaded one keeps playing until you pick another)
* PRÜFEN / ALLE PRÜFEN -> audio units: apple's `auval`, VST3: self-check (load, 1 s of noise, state read + written back, unload). both in their own process, pass / fail + the last lines of the log (click the row). cached per plugin and version, cancel any time
* status: ok · ungeprüft (not validated) · prüfung fehlgeschlagen (failed) · blockiert (crashed before) · nicht ladbar (with the reason in the row)
* folders always scanned: `/Library/Audio/Plug-Ins/Components`, `~/Library/Audio/Plug-Ins/Components`, AUv3 from apps (system registry), `/Library/Audio/Plug-Ins/VST3`, `~/Library/Audio/Plug-Ins/VST3`
* ORDNER HINZUFÜGEN … -> own folders. `.component` bundles in there (subfolders too) are loaded into MINOS-741 and registered for this app only, `.vst3` bundles are loaded from where they are, nothing is installed. folder changes trigger a rescan
* PLUGIN INSTALLIEREN … -> pick `.component` / `.vst3` bundles, folders or a `.zip` -> `.component` copied to `~/Library/Audio/Plug-Ins/Components`, `.vst3` to `~/Library/Audio/Plug-Ins/VST3` (created if missing, never `/Library`). an installed bundle with another version -> asks before replacing
* downloads carry a quarantine flag. gatekeeper may block unsigned or unnotarized plugins -> MINOS-741 asks before removing the flag, only say yes for sources you trust

#### VST3

* every effect class of a `.vst3` bundle (category audio effect, sub category Fx) is an own entry. the classes come from `Contents/Resources/moduleinfo.json` without loading code, otherwise the bundle is loaded once (with crash marker)
* runs in-process, `läuft im prozess` in the list. isolation is audio unit only -> a crashing VST3 takes MINOS-741 down, the crash marker blocks it on the next start
* stereo in / out (a mono plugin gets the mid signal), 32-bit float, blocks up to 4096 frames, the sample rate of the audio device
* parameters for knobs / buttons: all except bypass, program change, read-only and hidden. groups = the plugin's units, lists with their entry names
* the plugin gets the tempo of the master clock (tempo-synced delays follow)
* latency reported by the plugin is not compensated (same as audio units)
* tail: rendered until 1 s below -100 dB, or as long as the plugin's own tail time (max 30 s)
* EDIT -> the plugin's own view (resizable if the plugin allows it), else one slider per parameter
* state of processor + controller is saved with the session
* VST is a registered trademark of Steinberg Media Technologies GmbH. hosting via the VST 3 SDK (MIT) -> [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)

#### crash safety

* live rule (default): ⌘, -> PLUGINS -> `Plugins im Prozess (riskant)` off -> audio units from other vendors run only isolated in a separate system service. VST3 and plugins from own folders can only run in-process -> not loaded, not in the fx menu (`nur im Prozess – aus` in the list)
* isolated plugin crashes or renders nothing for 2 s -> the unit goes dry, notice, the plugin reloads after 2 s. 3rd crash -> blocked (count in the plugin row, BLOCK AUFHEBEN resets it). single blocks it missed -> notice `antwortet nicht rechtzeitig – n Blöcke trocken`, the signal stays dry for those blocks
* `Plugins im Prozess (riskant)` on -> as before: default isolated for third-party, per plugin default / isolated / in-process, VST3 and own folders in-process. a crash in-process ends minos
* apple plugins always load in-process
* cost of isolation, AUMatrixReverb, 512 frames at 48 kHz (budget 10.7 ms): no added latency, ~0.04 ms -> ~0.05 ms per block on the audio thread (mean), p99 0.06-0.16 ms -> 0.08-0.27 ms
* crash marker: before an in-process plugin (or its window, or a bundle from an own folder) opens, MINOS-741 notes it. if the app dies right there, the next start blocks that plugin and shows it in the PLUGINS tab. a blocked plugin never loads, also not from a saved session -> BLOCK AUFHEBEN to try again

## ◆ 09 · BROWSER

* one or two panes, side by side or stacked
* each pane: own tree, search, sort, role chips, tags
* favorites bar on top of each pane: 6 slots, source or filter. click = switch, right click = assign / rename / clear, drag a tree entry onto a slot, ⌃⌥1-6. details: [library · favorites](library.md#-favorites)
* tree: TRACK COLLECTION, RUNNING TRACKS, CUTS (cut files, see [cut audio](#cut-audio)), PREPARATION, PREPARATION ARCHIV, HISTORY, HISTORY ARCHIV, SMARTLISTS 741, MUSIC FOLDERS, then all playlists + smartlists of the collection
* MUSIC FOLDERS = the music library on disk, folder by folder. click a folder -> its audio files (mp3, m4a, aac, aiff, wav, flac, ogg, opus)
  * files in the collection show bpm, key, tags, comments like everywhere else
  * files not in the collection are grey, no grid, load and preview anyway
  * SUBFOLDERS in the list header -> all files below the folder
  * right click a folder -> rescan, show in finder. folders that change on disk are rescanned on their own
  * default folder = the folder holding 90 % of the collection's files, own folders: ⌘, -> DISPLAY -> browser
* all library columns: move by drag, hide via right click on the header, saved
* `√` = analyzed in the collection, purple `√` = own analysis (see [analyze](#analyze)), missing files show the artist in red
* search: artist, title, comment 1 + 2, label, genre, album, key. several words = all must match, case and accents ignored
* right click a track -> load into deck A-D, add to / remove from preparation, preview, show in finder, reset played state
* played column ▶: ✓ = played since the last reset. reset: right click a track or TRACK COLLECTION -> Reset Played State, or ⌥⌘P
* the left controller drives the left pane, the right controller the right one
* tree can hide while decks are visible (setting)
* cover preview below the tree: cover of the selected track, `◆ KEIN COVER` (`◆ NO COVER`) = none (setting)
* cover column (hidden by default): right click on the header -> Cover. thumbnails load only for visible rows, in the background
* info column ☁✓ = cloud state and analysed in one narrow column (the single columns `☁ Cloud` and `✓ Analysiert` stay available in the header menu). cloud (library in a cloud folder): ● local · ☁ online only · ↓ downloading · ✕ missing
* right click tracks or a source in the tree -> `Bereitmachen (herunterladen)`, progress + ✕ in the status bar
* ● LOKAL in the header -> local tracks only. SET-CHECK -> preparation + this list: what is not local, `ALLE HOLEN`
* details: [library · cloud libraries](library.md#-cloud-libraries)

### harmony + matching

reference = audible key of the master deck (track key + key shift, without keylock + tempo, rounded to semitones). no master playing -> focused deck.

* key column, colored on the open key wheel: `◆` purple = same · `▲` / `▼` light = ±1 · `◇` light = relative major / minor · grey = ±2 (energy) · dimmed = clash. off: ⌘, -> BROWSER
* column `Match`: pitch in % the track needs to reach the master tempo (dimmed outside the bpm window). click the header -> sort by harmony: distance to the master key, then tempo difference
* master or key shift changes -> only key and match cells of the visible rows redraw, the list stays
* `◆ PASST` (`◆ MATCH`) in the header -> only tracks with a fitting key (same, ±1, relative; ⌘, -> BROWSER) and tempo within ±4 % (half / double optional). shows the reference, follows master changes. a track without key never fits, a master without key filters by tempo only
* on / off: chip, ⌥⌘J (last used pane), browse push on the controller (⌘, -> CONTROLLER -> browse push)

### preview

a mini overview of the whole track per row. modes (⌘, -> DISPLAY -> browser preview):

* `Ganze Zeile (zweizeilig)` (default): rows twice as high, text on top, the overview as a band across the full row width underneath, continuous over all columns. selection and inline edit work as usual (the editor sits in the text line)
* `Eigene Spalte`: PREVIEW column after the title
* `Hinter dem Titel`: 25 % under the title text
* `Aus`


* waveform, colors `Spektrum (rot/grün/blau)` (default): red = bass, green = mids / synths, blue = highs / drums, mixed per column. bands are weighted against a typical track -> a bass-heavy track is redder, a hat-heavy one bluer. height from peak and bass, scaled per track -> breaks sit clearly lower, drops jump out. thin bright line = big energy jump (drop), at most 4 per track
* colors `wie Wellenform`: 3 bands in the palette of the waveform setting, muted
* grid stays in the background (phrase bands, lines every 16 / 32 bars), fainter with the spectrum colors
* phrase bands from the grid (phrase length = the waveform phrase), thin line every 16 bars, magenta every 32 bars
* hotcues as short colored ticks, start cue as a triangle on top. own grid / phrase anchor / hotcue edits are drawn too
* cut ([edit mode](#edit-mode)): outside dimmed, edges as a line with tabs. `Vorhören`: playhead in the row, click into that band jumps (outside the cut -> cut start, or 1 s before the cut end), status bar `Vorhören −1:23 / 4:10 (Schnitt)` = left to the cut end / cut length, ✕ = stop. output pair -> [preview output](#preview-output)
* no overview yet -> grid and cues only
* overview comes from: loading the track into a deck (free, from the deck's waveform) · right click TRACK COLLECTION, PREPARATION, a playlist, smartlist, playlist folder or music folder -> `Vorschauen berechnen` · background job (setting, `immer (gedrosselt)` by default)
* background order: rows on screen without an overview first (last shown first), then the whole collection, newest tracks first
* `immer (gedrosselt)`: runs while decks play: one file at a time, low priority, half the cpu time, 1 s between files. no deck playing -> full speed. `nur wenn kein Deck spielt`: waits while a deck plays. `aus`: only deck loads and right click
* every mode: computing waits while a deck loads and 4 s after, also in the middle of a file
* status bar: `Vorschauen 1.234 / 14.160 · gedrosselt` (tracks with overview / tracks with a file), `pausiert (Deck lädt)`, `pausiert (Deck spielt)`, ✕ = stop the background job until the next start. right click batch: `Vorschauen 12/240`, ✕ = cancel
* files that only exist in the cloud (placeholder, not downloaded) are skipped by the background job and counted: `12 nur online – Rechtsklick lädt`. right click -> `Vorschauen berechnen` reads them (downloads the file)
* ⌘, -> DISPLAY -> preview colors: spectrum / like the waveform
* overviews are checked against file size and modification time -> a retagged file gets a new one
* reload ↻ / ⌘O during a set: parsing, file check and sorting run in the background, the decks keep drawing. the lists switch in one step when everything is ready

role chips `BASIS · SYNTH · DRUMS · VOLL · ATMO` -> filter on the role at the end of comment 2 (`» BASIS`). several chips = any of them.

### analyze

right click tracks, TRACK COLLECTION, PREPARATION, a playlist, smartlist, playlist folder or music folder -> `Analysieren` / `Neu analysieren`.

* `Analysieren` = only what is missing: tempo + grid, key, loudness. nothing to do -> message. `Neu analysieren` = everything again (tracks locked in the collection: only what is missing)
* runs in the background like the previews: 2 files at a time, one file throttled while a deck plays, pause while a deck loads and 4 s after. status bar `Analyse 12/240`, `gedrosselt`, ✕ = cancel. done -> `Analysiert: 240 Tracks`, unreadable files are counted
* results: `analysis.json` in the MINOS-741 folder, on top of the collection and the metadata edits on every load. list, columns, sorting, search, smartlists, deck, sync, key readout and auto-gain use them. purple `√` in the list = own values (hover = what)
* right click -> `Analyse verwerfen` = back to the collection's values. a grid set by hand on the deck stays (RESET in the grid row removes it)
* a track on a deck keeps its grid until it is loaded again
* files from MUSIC FOLDERS without a collection entry get all four values too
* `Änderungen in die Collection-Datei schreiben` on (⌘, -> ANZEIGE -> browser): after a batch the analyzed entries go into `collection.nml` as `TEMPO`, `LOUDNESS`, `MUSICAL_KEY` and a grid marker (`CUE_V2` type 4, an existing marker keeps its place and hotcue slot), same backup and byte-exact replacement as the metadata edits, not while the library software runs
* values: bpm with 6 decimals, grid anchor in ms, key as `MUSICAL_KEY` 0–23 (shown as open key `1d`–`12m`), `PERCEIVED_DB` = gain to the collection's reference (positive = quiet track), `PEAK_DB` = headroom of the peak below 0 dBFS (positive = below)
* bpm range: ⌘, -> ANZEIGE -> analyse, exactly one octave (from / to move together, default 100–200). the tempo is folded into it (100–200: 96 -> 192)
* method: one pass, mono at ~22 kHz (key, loudness) and ~11 kHz (tempo, grid) · tempo from the spectral flux: fourier tempogram with a harmonic comb over 60–200 bpm, fine search at the beat frequency to 0.001 bpm, whole beats between the start and the end of the track (constant tempo assumed), cross-check against the majority of local tempi (8 s windows, 2 s hop, ±2 %), then folded into the bpm range · grid anchor: onset envelope (bass < 150 Hz + full band) folded on the beat with 1 ms resolution over the whole track, the phrase start from the structural changes (same logic as the phrase anchor), else the first beat · key: 250 ms frames (8192 fft, 125 ms hop), level per semitone in dB, threshold 50 dB under the loud frames and up to 20 dB higher for low notes, local masking (±5 semitones), folded 55 Hz–6.6 kHz, against krumhansl and temperley profiles (better one per mode, minor +5 %) · loudness: replaygain method, power per ~70 ms weighted with the 80 phon equal-loudness curve (iso 226), 95th percentile
* key profiles: right click TRACK COLLECTION or ⌘, -> ANZEIGE -> analyse -> `Key-Profile lernen`. up to 300 local tracks with a key from the collection (own analysis keys don't count, cloud-only files are skipped, nothing is downloaded), same background queue as the analysis, status bar `Key-Profile 12/300`, ✕ = cancel. profile = mean chroma per mode turned to C. every 5th track is held out and measured -> `Profile gelernt: 294 Tracks · exakt 55 %, vorher 31 %`. saved as `key-profiles.json` in the MINOS-741 folder, the analysis uses it from then on, else krumhansl / temperley. `Key-Profile verwerfen` deletes the file
* synthetic checks (`swift test`): click track -> tempo ±0.05 bpm, grid ±5 ms at 44.1 and 48 kHz, bpm range folding, chords -> key, sine -> loudness and peak, key profiles from synthetic chroma
* against the collection (`MIX741_ANALYZE_NML=<collection.nml> MIX741_ANALYZE_N=20 swift test --filter analyzerAgainstCollection`), 20 / 96 local tracks: bpm 18 / 20 and 80 / 96 within 0.1 (misses: integer bpm in the collection = set by hand, old vinyl tracks), key 8 / 20 and 34 / 96 exact (+4 / +24 related), with profiles learned from 300 other tracks 11 / 20 and 47 / 96 (`MIX741_ANALYZE_LEARN=300`), loudness median deviation 0.32 / 0.49 dB (max 1.1 / 1.4 dB), grid within 20 ms of the collection's marker 10 / 18 and 31 / 83 (m4a 15 / 22, median −4 ms; mp3 clusters at ~+10 and ~+48 ms = different decoder start, see [troubleshooting](#-14--troubleshooting)), ~0.9 s per track (release)

### edit tracks

editable: title, artist, release, mix, remixer, producer, label, catalog no, genre, comment, comment 2, key text, track #, release date, bpm (not for tracks locked in the collection), rating. not editable: file, time, bitrate, import, plays, played, key (analysis).

* inline: click a selected row again -> the cell turns into a field (double click still loads into the deck). return on a selected row = edit too
* in the field: return = apply, esc = cancel, tab / ⇧tab = next / previous editable column, click elsewhere = apply
* rating inline: click a star or type 0-5
* edit window: right click -> `Bearbeiten …` or ⌘E -> all fields, stars for the rating, PREV / NEXT, RESTORE · CANCEL · APPLY · OK
* one track: PREV / NEXT walk through the list (the list selection follows), changes of every visited track are applied together
* several tracks (⌘ / ⇧ click): first view `ALL n` -> equal values are shown, different ones show `‹mehrere›`. typing into a field ticks its box ■ = this value goes to all selected tracks. PREV / NEXT show the tracks one by one: unticked fields change only that track
* RESTORE = drop the input since opening or the last APPLY. invalid input (date, bpm, track #) turns red and is not applied
* list, search and sorting update right after APPLY
* changes live in `metadata.json` (MINOS-741 folder) on top of the collection, also after a reload. right click -> `Eigene Änderungen verwerfen` = back to the collection's values

### write into the collection file

off by default. ⌘, -> ANZEIGE -> browser -> `Änderungen in die Collection-Datei schreiben (Backup davor)`.

* on: 1.5 s after the last APPLY all pending changes go into `collection.nml` in one write
* before that a backup: `Backup MINOS-741/collection_YYYY-MM-DD_HHMMSS.nml` next to the collection, at most one per hour
* only the edited `ENTRY` blocks change, the rest of the file stays byte for byte the same. the new file is checked (readable, same track count) and replaces the old one atomically
* not while the library software is running (it keeps the collection in memory and overwrites the file on quit) -> status bar message, changes stay in MINOS-741 and go out with the next write
* written fields leave `metadata.json`, the file holds them now. a track whose entry changed in the file meanwhile is skipped (status bar) -> ↻ reload, edit again
* switching the setting on writes the changes made before
* tags inside the audio files are not touched

what goes into the file:

| from MINOS-741 | in the file | after writing |
|---|---|---|
| metadata (inline, ⌘E) | `ENTRY` / `ALBUM` / `INFO` / `TEMPO` attributes | leaves `metadata.json` |
| own analysis | `TEMPO BPM`, `LOUDNESS`, `MUSICAL_KEY`, first grid marker | marked written in `analysis.json` |
| hotcues 1-8: cue, loop (with length), fade, load | `CUE_V2` with `HOTCUE 0-7`, `TYPE 0/1/2/3/5`, `START` / `LEN` ms, `NAME` | leave `edits.json` |
| grid set by hand (bpm + anchor) | `TEMPO BPM` + `START` of the first `CUE_V2 TYPE="4"` (new marker if none) | leaves `edits.json`, stays when an own analysis with grid exists (the hand grid must stay on top) |
| renamed file (cut in place, other extension) | `LOCATION DIR / FILE / VOLUME / VOLUMEID` | leaves `collection-moves.json` |
| cut copies and tool loops (`cuts.json`) | new `ENTRY` before `</COLLECTION>`, `COLLECTION ENTRIES` counted | stays in CUTS too |
| preparation, own history sessions | `$ROOT/MINOS-741/Preparation`, `$ROOT/MINOS-741/History/History YYYY-MM-DD · NN` (`TYPE="LIST"`) | replaced on every write |

* hotcues: the hotcues of the entry are replaced by MINOS-741's set; unchanged ones keep their text, memory cues (`HOTCUE -1`) and grid markers stay. a grid marker sitting on a hotcue slot stays where it is
* locked entries (`LOCK="1"`): no bpm / grid written, the hand grid stays in `edits.json`
* entries with more than one grid marker (tempo changes): only the first marker is written, the others stay; MINOS-741 plays one tempo
* new entries have no `AUDIO_ID` (the library software computes it on its next analysis), `MODIFIED_DATE` / `MODIFIED_TIME` = now. options under ⌘, -> ANZEIGE -> browser: `Cuts und Tool-Loops als neue Einträge anlegen`, `Preparation und History als Playlists (Ordner MINOS-741)`, both on (only with writing on)
* own playlists: only the folder `MINOS-741` directly under `$ROOT` is written, replaced as a whole, its playlist ids stay the same per path. other folders and playlists are never changed or removed. tracks not in the file are left out
* stays in MINOS-741 only (the format has no place for it): trim (cut in / out), active loops, undo
* preparation changes write after 10 s, history sessions go out with the next write (no write per played track)

reading back (↻ or a write that finds the file changed):

* before writing, size + modification time of the file are compared with the last read. changed -> reload first, then write
* MINOS-741 keeps per open change the entry's `MODIFIED_DATE` / `MODIFIED_TIME` from when the change was made
* entry unchanged in the file -> MINOS-741's open changes stay on top and go out with the next write
* entry changed in the file, no open change in MINOS-741 -> the file's values
* both changed (conflict) -> the file wins for the whole entry. MINOS-741's open metadata go to `metadata-konflikt.json`, hotcues / grid to `edits-konflikt.json` (Application Support, newer entries replace older ones with the same key); trim and active loops stay. status bar: `Konflikt: n Tracks …`
* changes made before this version carry no stamp -> no conflict check for them
* the result is checked before it replaces the file: readable, track count + new entries, written cues / grid / moved entries / own playlist folder read back the same

### check the collection

BROWSER menu -> `Collection prüfen …` or right click TRACK COLLECTION. read only, nothing is changed.

* window like an old installer: progress `n / total · % · time · ~left`, the current file ticking by, the log rattling down (`OK   …/file.mp3`, `MISS …`), counters per check
* ABBRECHEN stops at once, the findings so far stay. a file that hangs on a cloud drive finishes in the background, its result is dropped
* after the run: FINDINGS table, click a counter = filter. right click / double click -> show in browser (selects the track in TRACK COLLECTION), show in finder, copy path. REPORT TXT / CSV
* while running the log shows the newest lines (redrawn at most 10× per second), afterwards the last 2000 lines to scroll back. the findings table keeps all
* paths below the music folder show as `…/`

| tag | check | |
|---|---|---|
| `MISS` | file not found at the collection's path | problem |
| `PERM` | no read permission | problem |
| `ZERO` | file is 0 bytes | problem |
| `BAD ` | no audio header (only the header is opened, nothing is decoded) | problem |
| `TIME` | file duration differs from the collection by more than 2 s | problem |
| `CASE` | path differs in upper / lower case on disk | hint |
| `NFD ` | same name, other unicode form (nfc / nfd). no effect on the mac, can break copies to other systems | hint |
| `NAME` | file name contains neither title nor artist (case, accents, track numbers, bracket parts ignored) | hint |
| `DUP ` | the same file twice in the collection | problem |
| `TWIN` | same artist + title (+ mix) with another file | hint |
| `ANLZ` | no bpm, grid, key or loudness | hint |
| `GRID` | bpm outside 60-200, or the grid anchor after the end of the file | hint |
| `LIST` | playlist / preparation entry without a track in the collection | problem |
| `NEW ` | audio file in the music folders, not in the collection | hint |

* 6 files at a time. 14,160 tracks on a local drive: ~5 s
* `NEW` needs the music folder scan (setting, on by default)
* ⌘, -> DISPLAY -> check collection: check on start (off), scan music folders (on)

## ◆ 10 · TAGS + SMARTLISTS

comment 2 is split into tags at a separator (⌘, -> DISPLAY, default space, mine `·`):

```
K tief kurz · B sub leicht roll · H off » BASIS
-> K tief kurz | B sub leicht roll | H off » BASIS
```

* TAGS ▾ -> all tags of the source with counts, click = filter, ⌥-click = exclude, several = all must match
* comment 2 column: tags as chips -> click = filter by that tag, again = off, ⌥-click = exclude. click next to the chips selects / edits as before
* active filter as chips in the pane header (included filled, excluded struck through) -> click removes one, ✕ TAGS clears all. saved per pane in the session
* whole tags, case and accents ignored (`Kühl` = `kuhl`)
* tags get highlight colors
* "smartlist from tags" -> saves the current tag filter as smartlist (excluded tags as `!%`)

smartlists:

* all smartlists of the collection work as they are
* own ones under SMARTLISTS 741 -> + new smartlist, same query syntax, live count

```
$COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
```

full syntax -> [nml files](nml-files.md#-smartlist-queries).

## ◆ 11 · HISTORY + PREPARATION

history:

* a track counts as played after 30 s audible (setting)
* internal mode: only with fader / crossfader open. external mode: always
* saved as nml under `history_2026-10-10-01.nml` (day + session number), optional copy into the collection's history folder (time-stamped name)
* quitting asks first (also the red close button and ⌘W on the main window), then session and history are written
* HISTORY = this session, HISTORY ARCHIV = own + all sessions in that folder

preparation:

* right click -> add to preparation
* on every start: archived as playlist nml, then cleared
* PREPARATION ARCHIV -> old lists

export: right click collection, preparation, history or a playlist in the tree -> nml, m3u or folder with the audio files.

## ◆ 12 · KEYS

defaults below. every shortcut can be changed under ⌘, -> KEYBOARD: click the shortcut, press the new key (esc = cancel), ✕ = none, ↺ = default, RESET ALL. a key used twice turns red, the first action in the list wins. deck keys act on the focused deck.

| key | action |
|---|---|
| ⌘1-4 | focus deck A-D |
| ⌘space | play / pause |
| ⌥⌘C | cue (hold = cue held) |
| ⌥⌘V | cup |
| ⌘Y | sync |
| ⌘L | auto loop |
| ⌥⌘← / → | beatjump |
| ⌃⌘1-8 | hotcue 1-8 |
| ⌥⌘P | reset played state |
| ⌥⌘M | mixer on / off |
| ⌥⌘4 | 2 / 4 decks (from 1 deck -> 4) |
| ⌃⌥⌘1-4 | view profile 1-4 |
| ⌃⌥⇥ | next view profile |
| ⌥⌘B | big browser |
| ⌥⌘K | compact decks (pitch fader, hotcues, grid tools off / on) |
| ⌥⌘E | edit mode on the focused deck |
| ⌘+ / ⌘− / ⌘0 | zoom in / out / actual size |
| space | big browser (not while typing in a search field) |
| ⌘O | open collection |
| ⌘E | edit the selected tracks (browser) |
| ⌃⌥1-6 | browser favorite 1-6 (last used pane) |
| ⌥⌘J | browser: matching on / off (last used pane) |
| ⌘, | settings |
| ⌘W | close window -> main window: quit (asks first) |
| esc | clear the marked range (only when one exists, not in a search field) |
| ⌘Z / ⇧⌘Z | undo / redo (text undo inside a text field) |

no default, assignable: master, keylock, key sync, instant double (from the neighbour deck), reloop, cut start here, cut end here, grid beat 1 here, remove range (new file), keep range (new file), cut in / out from range, loop from range, load selection into the focused deck, load selection even if the deck plays, preview selection, reload collection, reconnect audio.
⌘Q, ⌘H, ⌘M and ⌃⌘F stay with the system. keys without ⌘ / ⌥ / ⌃ never fire inside a search field.

controller mapping -> [controllers.md](controllers.md). flux on the controller = pad layer switch: tap -> pads 1-4 play hotcues 5-8 (flux led lit), tap again -> back, shift + flux = tap (grid bpm from the taps; setting: flux mode instead), shift + sync = master. old layout under ⌘, -> CONTROLLER -> flux button.

## ◆ 13 · FILES + FOLDERS

| what | where |
|---|---|
| collection (read, write only on request) | newest `collection.nml` in the library folder |
| collection backups (write-back on) | `Backup MINOS-741` next to `collection.nml` |
| track metadata edits | `~/Library/Application Support/MINOS-741/metadata.json` |
| settings | user defaults, key `prefs.v1` |
| session (decks, fx, clock, browser) | `~/Library/Application Support/MINOS-741/session.json` |
| hotcue, grid + cut edits | `~/Library/Application Support/MINOS-741/edits.json` |
| cut files (metadata, CUTS) | `~/Library/Application Support/MINOS-741/cuts.json`, the files next to their originals |
| browser previews (track overviews) | `~/Library/Application Support/MINOS-741/overviews/overviews.bin` |
| own analysis (tempo, grid, key, loudness) | `~/Library/Application Support/MINOS-741/analysis.json` |
| history | `~/Library/Application Support/MINOS-741/History` |
| preparation archive | `~/Library/Application Support/MINOS-741/Preparation` |
| cover thumbnails (cache, safe to delete) | `~/Library/Caches/MINOS-741/artwork` |

backup = copy the `MINOS-741` folder.

## ◆ 14 · TROUBLESHOOTING

| problem | fix |
|---|---|
| controller does nothing | close other dj software, replug, ⌘, -> CONTROLLER -> BLINK |
| no sound | ⌘, -> AUDIO: device + mode + pair, check the status bar |
| sound on the wrong desk channel | external mode -> deck → channel pairs |
| sync won't engage | track has no grid -> analyze it in your library software once |
| link peers but no tempo | LINK on in both apps, same network, firewall |
| crackles | other apps on the same device, sample rate set in audio midi setup |
| DROPOUTS counts up | DSP near or above 100 % -> bigger buffer (⌘, -> AUDIO), fewer keylock decks / plugins. DSP low but dropouts -> device or system (other audio apps, usb hub, energy saver) |
| DSP red | single blocks over 70 %: plugins, 4 decks with keylock, small buffer. average matters, a single peak after loading is normal |
| latency too high | buffer size in ⌘, -> AUDIO. LATENCY = buffer + device + safety offset; keylock lookahead is compensated and not audible as delay |
| track won't load | status bar message: `Datei fehlt` = path in the collection wrong; `lädt noch (4 s ohne Daten)` = the cloud provider is still delivering the file, the deck keeps loading; `(60 s) keine Audiodaten (Drive antwortet nicht)` = nothing came, the helper was stopped -> load again or take another track; otherwise the format reason. limits in ⌘, -> AUDIO -> loading & cache |
| ☁ in the list, set-check not clean | right click -> `Bereitmachen`, or `ALLE HOLEN` in the set-check. for good: finder -> right click the library folder -> make available offline |
| local tracks turn ☁ again | macos evicted them (optimize storage, low disk space) -> keep local in ⌘, -> CLOUD fetches them again; pin the folder, free some space |
| downloads don't start | a deck is loading (status bar `pausiert`), or less than the free space floor left (⌘, -> CLOUD) |
| artist in red | file missing or moved -> fix the path in the collection, reload ↻. all of them at once: BROWSER -> `Collection prüfen …` |
| check takes long | cloud drive downloads files on first access -> ABBRECHEN keeps what was found, check again later |
| ui hangs | audio + sync keep running. report it with the version from the title bar |
| own grid vs the collection's marker off by ~10 or ~48 ms on mp3 | not an analysis error: the mp3 decoder of MINOS-741 starts the audio at a different sample than the library software (encoder delay, info frame). measured on 57 mp3: two clusters at ~+10 and ~+48 ms (collection later), m4a −4 ms. MINOS-741 plays with the same decoder it analyzes with -> own grids fit. collection grids on such mp3 may sit that much late in MINOS-741, written-back grids that much early in the library software. not corrected |

self test (silent, ends by itself):

```
MIX741_SELFTEST=1 MIX741_NOEXT=1 swift run minos741
```

waveform still without a window: `MIX741_SHOT=wave:/tmp/wave.png` in addition -> one deck with loop and hotcues as png, then exit.
whole deck: `MIX741_SHOT=deck:<png>` -> deck A with comment + tags at 640×300 and 480×260, compact at 640×300 (`-compact`), edit mode with cut and own grid at 640×300 and 480×260 (`-edit-`), built-in output, then exit.
settings as png without a window: add `MIX741_SHOT=settings:<folder>` -> one image per section, then quit.
status bar, failed and empty deck as png: `MIX741_SHOT=status:<folder>` (add `MIX741_SHOT_AUDIO=1` for live meters, silent on a built-in device).
collection check without a window: add `MIX741_CHECK=1` -> counts per check and duration, `MIX741_CHECK_LIST=<n>` lists the first n findings each. `MIX741_SHOT=consistency:<png>` renders the check window mid-run and finished.
reload stall: add `MIX741_BENCH=reload` -> loads and reloads the collection offscreen, prints the longest main-thread gap per reload (`MIX741_BENCH_N` rounds).
load probe on the device: add `MIX741_BENCH=load` -> 4 decks with keylock, reverb on fx 1, plugin on fx 2 (`MIX741_BENCH_PLUGIN=<id>|none`), delay on fx 3 (all decks), buffers `MIX741_BENCH_BUFFERS` (512,256,128) for `MIX741_BENCH_SECS` s (8) each, a line per minute, prints dsp load, peak, blocks over budget and device overloads per buffer size (`[selftest] Lastprobe`). offline core numbers without a device: `MIX741_BENCH=1 swift test --filter benchRenderCPU`.
memory with long tracks: add `MIX741_BENCH=memory` (`MIX741_BENCH_MIN` = minimum length in minutes, 10; `MIX741_CORE_RATE=96000` = core at the live rate, device untouched) -> 4 local tracks, rss, wired memory, mlock failures, memory pressure, then 4 decks keylock.
ui cost (no selftest needed, offscreen, silent on a built-in output): `MIX741_BENCH=state` -> play, sync, loop, sizes, hotcue, tempo, keylock, clock bpm, edit mode on / off, cut on deck A, median / p95 / max per action (`MIX741_BENCH_N`, `MIX741_BENCH_EDIT=1` = deck A in edit mode, `MIX741_BENCH_UI=live` = two browsers without mixer, `MIX741_BENCH_LAYOUT=1` layout time per hosting view, `MIX741_BENCH_ONLY=play,hotcue`). `MIX741_BENCH=play` -> 2 or 4 decks play (`MIX741_BENCH_DECKS`, `MIX741_BENCH_SECS`): main thread load, hitches, waveform steps per frame (`MIX741_BENCH_RAW=1` = playhead unsmoothed).
browser cost with 4 decks playing (offscreen, silent on a built-in output): `MIX741_BENCH=browser` -> search, typing, roles, tags, sort, source, scroll, preparation, load, analysis results, session, idle on pane A. per action the time until the main thread is free, every main-thread gap > 16 ms (`MIX741_BENCH_ONLY=search,sort`, `MIX741_BENCH_N`, `MIX741_BENCH_UI=live`, `MIX741_BENCH_ALL=1` every value, `MIX741_BENCH_PREVIEW=row|column|title|off`, `MIX741_BENCH_PROFILE=<phase>` main-thread profile by function, `MIX741_BENCH_SAMPLE=<file>` full call tree via `sample`).
cloud column + set-check as png: `MIX741_SHOT=cloud:<folder>` -> real check of the collection in the log, images with real and with set states, nothing downloaded.
tag chips as png: `MIX741_SHOT=tags:<folder>` -> pane with tag filter, chip click checks, filter and paging times (`MIX741_SHOT_FULLROW=1` two-line rows, `MIX741_SHOT_TEXT=<pt>` their text size, `MIX741_SHOT_PAGES=<n>`).

### ui test

```
MIX741_SELFTEST=1 MIX741_NOEXT=1 MIX741_UITEST=1 .build/debug/minos741
scripts/uitest.sh [--fixture] [--only <case,…>] [--limit <s>] [--no-build]   # debug build, killed after 120 s
```

* real main window (content view, toolbar, all environments) offscreen at −30000, transparent, app never active. synthetic `NSEvent`s through `NSWindow.sendEvent` (mouse) and `NSApp.sendEvent` (keys, local monitors see them). silent on a built-in output, saves nothing
* cases: right click on deck A's title -> `Track bearbeiten …` -> edit sheet opens and closes · track key dropped on deck A's header -> loaded · ⌃ + drag in waveform A -> range on beats, esc -> cleared · double click on the title column divider -> width of the longest title · status bar automatic: mouse at the bottom edge -> shown, away -> still shown after 0.2 s, gone by 0.8 s · play/pause key from the settings -> deck A plays / stops; a plain play key in the search field is typed, deck A stays, space does not toggle the big browser · toolbar MIXER and decks 1 / 2 / 4 by click (deck C built, deck B gone, back) · ⌘− / ⌘+ -> zoom 0.9 / 1
* end: `UITEST OK` (exit 0), `UITEST ÜBERSPRUNGEN` (no audio device or no 3 local tracks with grid, exit 0), else the first error (exit 1). a missing environment crashes the process (exit ≠ 0)
* `MIX741_UITEST_ONLY=zoom,drop` runs the cases starting with these names. no collection or `MIX741_UITEST_FIXTURE=1`: 3 generated wav files (20 s, kick per beat, 126 / 128 / 130 bpm, grid at 0) and an nml in `$TMPDIR/minos741-uitest-<pid>`, removed at the end
* runtime (debug build, whole process): 11 s with the fixture, 18 s with a 14k collection
* limits: context menus come from `menu(for:)` of the hit view and are not shown (a real right click blocks in a modal menu). drop without a dragging session (needs the window server): the pasteboard goes to the view swiftui registers for `onDrop`, the drag source is not covered. hover: enter / exit / move are handed to the tracking-area owners (synthetic moves trigger no tracking areas, tooltips left out). keys: an inactive app does not route keys to its window -> plain keys go to the window only while a text field has focus. the menu bar is not built

### live load test (interface)

```
scripts/loadtest.sh --minutes 30          # release build, first external interface (≥ 8 outputs)
tail -f ~/Library/Application\ Support/MINOS-741/loadtest/latest.log
```

* stages: buffer 512 -> 256 -> 128 (`--buffers 512,256,128,64`), `--minutes` each (10)
* per stage: 4 local tracks, keylock, B-D synced to A, link on, fx 1 (A/C) + fx 2 (B/D) delay + reverb, fx 3 (all) isolated plugin (`--plugin <id>|none`, default apple matrix reverb isolated)
* stress: track change on B / C / D every 60 s (file service), search + sort over the collection every 20 s, main thread blocked 1 s every 5 min
* routing external A 1/2 · B 3/4 · C 5/6 · D 7/8, master 0 dB -> turn the desk down first. `--mute` silent, `--out <name>` picks the device, `--builtin` built-in output (silent)
* log: dsp mean / peak, blocks over budget, device overloads, main-thread hitches > 16 ms, link phase every 10 s, rss, track load times, file service helpers, mlock failures. table per stage with PASS / FAIL: peak < 70 %, 0 over budget, 0 overloads, link phase < 0.02 beats. 3 device overloads -> stage FAIL, next stage runs
* ctrl-c -> summary so far, output off. self test mode: no settings, session or cache of yours written
* `--debug` = debug build (dsp much slower, only to check the runner), `--no-build`

bugs -> [issues](https://github.com/Slayer7411/MINOS-741/issues) with version, macos, device, mode, controller.

## ◆ 15 · FAQ

**does it change my collection?**
no. `collection.nml` is only read. edits go to own files.

**do i need another dj software?**
for analysis yes (bpm, key, grid). playing and mixing no.

**windows / ipad?**
no. macos only, native coreaudio.

**other controllers?**
only the 2-deck hid controller so far. midi learn is planned -> [roadmap](roadmap.md).

**why gpl?**
the link library is GPL-2.0-or-later -> the whole app is.

**can i change it for my own setup?**
fork it. ideas back -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions).
