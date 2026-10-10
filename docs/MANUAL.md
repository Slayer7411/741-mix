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

1. close traktor (the x1 can only talk to one app)
2. start MINOS-741 -> it loads `~/Native Instruments/Traktor 3.11.2/collection.nml`
   other collection -> ⌘O
3. ⌘, -> AUDIO -> pick the output device and the mode
   * INTERNAL -> mixer in the app, master on one pair
   * EXTERNAL -> every deck on its own usb pair into your desk
4. ⌘, -> CONTROLLER -> check which x1 drives which decks, BLINK shows the unit
5. double click a track = load into the focused deck (⌘1-4), right click -> load into deck A-D, or LOAD on the x1

nothing is analyzed. bpm, key, grid, cues and loudness come from the traktor collection.
tracks without a traktor analysis play, but have no grid -> no sync.

## ◆ 03 · SCREEN

```
┌ toolbar ───────── MIXER · 2 / 4 DECKS · browser layout · DECKS · ↻ ┐
├ FX 1 ─────────┬ master clock + link + metronome ─┬ bars ──┬ FX 2 ─┤
├ deck A ───────────────────────┬ deck B ────────────────────────────┤
├ deck C ───────────────────────┼ deck D ────────────────────────────┤
├ browser pane 1 ───────────────┼ browser pane 2 ────────────────────┤
└ status: tracks · collection · load time ── device · mode · routing ┘
```

* MIXER -> internal mixer on / off (⌥⌘M)
* 2 DECKS / 4 DECKS (⌥⌘4)
* browser layout -> one pane, side by side, stacked
* DECKS -> hide decks, big browser (⌥⌘B)
* ↻ -> reload the collection
* the line between decks and browser can be dragged, the height is saved
* fullscreen -> toolbar hides, comes back with the mouse at the top

## ◆ 04 · DECKS

### header

```
A  title                 FX1 FX2    -1:10  130.00   11m   ±8 ▾
   artist                            33.2  +0.00%
```

* deck letter turns red while playing
* FX1 / FX2 (… FX4) -> deck on that fx unit
* remaining time, bpm, tempo offset, key (open key, e.g. `11m`), key shift
* `±8 ▾` -> tempo range ±6 / 8 / 10 / 16 / 50 / 100 %

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

### cues + loops

| button | action |
|---|---|
| 1-8 | hotcue: click = jump / set, ⌥-click = delete |
| IN / OUT | manual loop |
| ◂ 4 ▸ | auto loop size 1/32 … 32, click on the size = loop on / off |
| RE | reloop |
| ◀◀ 4 ▾ ▶▶ | beatjump 1/4 … 64. inside a loop = move the loop |

* hotcues come from the collection. colors: start cue red, cues white, loops green, short loops magenta (⌘, -> DISPLAY)
* edits are saved in an own file. the collection stays untouched
* SNAP -> cues and loop points lock to the beat
* QUANT -> jumps keep the beat phase

### tempo

* fader on the right: drag = tempo, double click = 0
* ‹ › -> pitch bend while held
* 0 -> tempo back to 0 %
* synced decks can't be moved by hand, only the master

### load

* double click = focused deck, right click -> load into deck A-D, x1 LOAD = selected track of its own pane
* jumps to load cue / grid, track start or hotcue 1 (⌘, -> DECKS)
* first load: keylock on (setting)
* track end warning: remaining time blinks red x seconds before the end (0 = off)

## ◆ 05 · WAVEFORM + GRID

* drawn on the gpu as vectors -> sharp at any zoom
* height = real file level, full height = 0 dBFS, no normalizing -> loud masters look loud
* styles: 3-band layers / spectrum / mono, palettes: 741 bone / orange / blue / traktor
* drag the waveform = scrub, click the overview = jump
* played part can be dimmed

beatgrid:

* hairline beats, bar lines with caps top and bottom, bar numbers on the ruler
* phrases (16 / 32 / 64 / 128 beats) in purple, phrase countdown at the play head (`P3 · 16 T`)
* magenta markers every 8 / 16 / 32 bars (setting)

grid row (`GRID`):

| button | action |
|---|---|
| ◂◂ ◂ ▸ ▸▸ | move the grid 10 / 1 ms |
| BPM − / + | ±0.01 bpm |
| ÷2 ×2 | half / double bpm |
| SET | beat 1 at the play position |
| RESET | grid from the collection |

## ◆ 06 · SYNC / CLOCK / LINK

```
LINK 1 │ AUTO  128.00  − +  │ TICK ◯ │ S │ MAIN ◯ ⚙
       │ MASTER  DECK B  TAP│        │ Q │
```

* AUTO -> a deck is master (automatic or via MASTER on the deck)
* MASTER -> the clock is master, all synced decks follow it
* tempo: drag the number or − / +, TAP = tap tempo
* TICK -> metronome on the clock beat, own volume, own output pair (setting)
* S = snap, Q = quant
* MAIN -> main volume (internal mode)

sync modes (⌘, -> DECKS):

* DYNAMIC -> tempo + phase, always pulls back to phase 0
* FIXED -> a shifted phase stays shifted
* TEMPO ONLY -> no phase lock

phase lock runs on its own thread: tempo every tick, phase via a small rate nudge, hard jump only if the error stays > 0.25 beats.

ableton link:

* LINK -> join the link session, the number = peers
* minos leads tempo and bar, ableton follows
* link beat is time stamped in the audio callback -> no drift
* offset setting for latency between the two apps

bar counter (top right): runs from the first play, 4 / 8 / 16 bars, double click = back to bar 1.

## ◆ 07 · MIXER + AUDIO

### internal mode

per channel (order C · A · B · D like traktor):

* gain + auto-gain (loudness from the collection)
* eq hi / mid / lo, knob fully left = kill (setting)
* one-knob filter: left = low pass, right = high pass
* fx assign, channel fader, crossfader assign + curve (smooth / sharp)
* headroom per mode (internal default −3 dB)
* no limiter on purpose, hard clip as last stage

### external mode

* every deck on its own pair, default A 1/2 · B 3/4 · C 5/6 · D 7/8 (xone:96)
* gain / eq / fader happen on your desk
* own headroom and auto-gain setting, main volume off by default (like traktor)
* metronome on an own pair

routing is in ⌘, -> AUDIO. the device sample rate is never changed by minos.
the status bar shows device, mode and routing.

## ◆ 08 · FX

2 or 4 units (⌘, -> MIXER & FX). each unit:

* GRP -> group mode: FILTER · DELAY · REVERB at once, D/W + one knob + ON each
* SNGL -> single mode: one effect, 3 parameters
* delay time in beats (`1 ▾`), beat synced to the deck tempo
* ROOM -> reverb size
* deck assign: FX1 … FX4 in the deck header or the mixer
* default: FX1 -> A / C, FX2 -> B / D

effects so far: filter, delay, reverb. more -> [feature parity](feature-parity.md).

## ◆ 09 · BROWSER

* one or two panes, side by side or stacked
* each pane: own tree, search, sort, role chips, tags
* tree: TRACK COLLECTION, PREPARATION, PREPARATION ARCHIV, HISTORY, HISTORY ARCHIV, SMARTLISTS 741, then all traktor playlists + smartlists
* all traktor columns: move by drag, hide via right click on the header, saved
* `√` = analyzed in traktor, missing files show the artist in red
* search: artist, title, comment 1 + 2, label, genre, album, key. several words = all must match
* right click a track -> load into deck A-D, add to / remove from preparation, preview, show in finder
* the left x1 drives the left pane, the right x1 the right one
* tree can hide while decks are visible (setting)

role chips `BASIS · SYNTH · DRUMS · VOLL · ATMO` -> filter on the role at the end of comment 2 (`» BASIS`). several chips = any of them.

## ◆ 10 · TAGS + SMARTLISTS

comment 2 is split into tags at a separator (⌘, -> DISPLAY, default space, mine `·`):

```
K tief kurz · B sub leicht roll · H off » BASIS
-> K tief kurz | B sub leicht roll | H off » BASIS
```

* TAGS ▾ -> all tags of the source with counts, click = filter, several = all must match
* tags get highlight colors
* "smartlist from tags" -> saves the current tag filter as smartlist

smartlists:

* all traktor smartlists work as they are
* own ones under SMARTLISTS 741 -> + new smartlist, same query syntax, live count

```
$COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
```

full syntax -> [traktor files](traktor-files.md#-smartlist-queries).

## ◆ 11 · HISTORY + PREPARATION

history:

* a track counts as played after 30 s audible (setting)
* internal mode: only with fader / crossfader open. external mode: always
* saved as traktor history nml, optional copy into traktors history folder
* HISTORY = this session, HISTORY ARCHIV = own + all traktor sessions

preparation:

* right click -> add to preparation
* on every start: archived as traktor playlist nml, then cleared
* PREPARATION ARCHIV -> old lists

export: right click collection, preparation, history or a playlist in the tree -> traktor nml, m3u or folder with the audio files.

## ◆ 12 · KEYS

| key | action |
|---|---|
| ⌘1-4 | focus deck A-D |
| ⌘space | play / pause focused deck |
| ⌘Y | sync |
| ⌘L | auto loop |
| ⌥⌘← / → | beatjump |
| ⌥⌘M | mixer on / off |
| ⌥⌘4 | 2 / 4 decks |
| ⌥⌘B | big browser |
| ⌘O | open collection |
| ⌘, | settings |

kontrol x1 mk2 mapping -> [controllers-x1-mk2.md](controllers-x1-mk2.md).

## ◆ 13 · FILES + FOLDERS

| what | where |
|---|---|
| collection (read only) | `~/Native Instruments/Traktor 3.11.2/collection.nml` |
| settings | user defaults, key `prefs.v1` |
| session (decks, fx, clock, browser) | `~/Library/Application Support/MINOS-741/session.json` |
| hotcue + grid edits | `~/Library/Application Support/MINOS-741/edits.json` |
| history | `~/Library/Application Support/MINOS-741/History` |
| preparation archive | `~/Library/Application Support/MINOS-741/Preparation` |

backup = copy the `MINOS-741` folder.

## ◆ 14 · TROUBLESHOOTING

| problem | fix |
|---|---|
| x1 does nothing | close traktor, replug, ⌘, -> CONTROLLER -> BLINK |
| no sound | ⌘, -> AUDIO: device + mode + pair, check the status bar |
| sound on the wrong desk channel | external mode -> deck → channel pairs |
| sync won't engage | track has no grid -> analyze it in traktor once |
| link peers but no tempo | LINK on in both apps, same network, firewall |
| crackles | other apps on the same device, sample rate set in audio midi setup |
| artist in red | file missing or moved -> fix the path in traktor, reload ↻ |
| ui hangs | audio + sync keep running. report it with the version from the title bar |

self test (silent, ends by itself):

```
MIX741_SELFTEST=1 MIX741_NOXONE=1 swift run minos741
```

bugs -> [issues](https://github.com/Slayer7411/MINOS-741/issues) with version, macos, device, mode, controller.

## ◆ 15 · FAQ

**does it change my traktor collection?**
no. `collection.nml` is only read. edits go to own files.

**do i need traktor?**
for analysis yes (bpm, key, grid). playing and mixing no.

**windows / ipad?**
no. macos only, native coreaudio.

**other controllers?**
only the x1 mk2 so far. midi learn is planned -> [feature parity](feature-parity.md).

**why gpl?**
ableton link is GPL-2.0-or-later -> the whole app is.

**can i change it for my own setup?**
fork it. ideas back -> [discussions](https://github.com/Slayer7411/MINOS-741/discussions).
