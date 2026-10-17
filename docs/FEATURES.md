# FEATURES

everything MINOS does today (beta). details -> [MANUAL](MANUAL.md).

## ◆ DECKS

* 4 decks (A-D), show 1, 2 or 4; hidden decks keep playing
* classic deck set: play, CUE (hold = preview), CUP, reverse, undo
* FLUX: loops, jumps and reverse run in the background, release -> back where the track is
* DBL: instant double of the neighbour deck, same position, plays in sync, no reload
* KEY: keylock, tempo changes keep the pitch; key shift -12 to +12 semitones
* KEY SYNC: shifts the key to fit the master, at most ±6 semitones
* tempo fader with ±6 / 8 / 10 / 16 / 50 / 100 % range, double click = 0
* load lock: a playing deck takes no track (⌥ or shift forces it)
* track end warning, remaining time counts to the cut end
* cover art and tags in the deck header
* right click on a deck -> track menu (edit, show in browser, preview, rating, analyse)
* undo / redo for deck edits (⌘Z / ⇧⌘Z), up to 100 steps
-> [MANUAL 04](MANUAL.md#-04--decks)

## ◆ LOOPS + HOTCUES + BEATJUMP

* 8 hotcues per track: click = jump or set, ⌥-click = delete
* hotcues come from the collection, your edits are saved in an own file
* auto loop 1/32 to 32 beats, loop IN / OUT, RE (reloop), LOOP on / off
* active loop: engages when the playhead reaches it, no jump, per track saved
* auto loop on load (4-32 bars, off by default): marked AUTO, not active
* SNAP locks cues and loop points to the beat; loop snap uses stored loops and 4-bar boundaries
* QUANT keeps the beat phase on jumps
* beatjump 1/4 to 64 beats; inside a loop it moves the loop along
* ROLL beat fx: repeats the last length, the deck keeps running underneath
* controller: sync held + hotcue 3 / 4 = one beat back / forward
-> [MANUAL 04](MANUAL.md#-04--decks)

## ◆ SYNC / CLOCK / LINK

* SYNC: deck follows the master tempo and phase; sync modes dynamic, fixed, tempo only
* SEMI: a newly loaded track takes the master tempo, no phase lock
* MASTER: the clock or any deck can be the tempo master; AUTO picks a playing deck
* tap tempo, tempo field, metronome on its own output pair
* LINK: network tempo sync with other apps; minos can lead tempo and bar
* link offset (±50 ms) for a constant shift; link diagnosis via right click
* code readout per deck: bar in phrase against the master bar counter
* bar counter, phrase line and beat readout in the top bar
-> [MANUAL 06](MANUAL.md#-06--sync--clock--link)

## ◆ WAVEFORM + GRID

* 3-band blend waveform (bass red, mids green, highs blue), 6-band spectrum or mono
* blend presets A-K and 741 palettes, own presets, changed live
* sharp at any zoom, 1 to 16 seconds per side
* drag to scrub; grab like a record (vinyl or jog)
* overview under each deck, click to jump
* beatgrid with bar numbers, phrase lines (16 to 128 beats), markers every 8 / 16 / 32 bars
* other decks shown on the waveform, purple when in phase
* grid tools: move ±10 / 1 ms, bpm ±0.01, ÷2 ×2, TAP, SET, RESET
* grid anchor ±1 bar or beat; phrase anchor suggestion on load (off / suggest / automatic)
* daw bridge: takes the grid of a clip playing in your daw
-> [MANUAL 05](MANUAL.md#-05--waveform--grid)

## ◆ MIXER + AUDIO

* internal mixer: gain, auto-gain, 3-band eq with kill, one-knob filter, fader, crossfader + curve
* external mixer mode: every deck on its own usb pair (tested with Xone:96)
* auto-mix (internal mixer): picks the next track by key, tempo and tag match
* auto-mix transitions on phrase boundaries with bass swap and filter sweep, 8 / 16 / 32 bars
* level meters per deck and master; headroom per mixer mode
* no limiter on purpose, hard clip as the last stage
* preview on its own output pair, never on the system default output
* buffer test (⌘,) finds the smallest buffer size that runs safely on your device
* decks can render in parallel, one thread per deck, switchable while playing
* device unplugged -> decks keep state, output reopens when the device is back
-> [MANUAL 07](MANUAL.md#-07--mixer--audio)

## ◆ FX + PLUGINS

* 2 or 4 fx units, each a rack of up to 6 insert slots in series
* 7 built-in effects: filter, delay, reverb, gater, roll, flanger, phaser
* reverb: 2 types, freeze (FRZ), send mode for big washes
* beat fx grid follows the master clock
* audio unit (v2, v3) and vst3 plugins in any slot
* audio units run isolated by default: a plugin crash does not stop the audio
* vst3 runs inside the app: a crashing vst3 ends minos
* quick controls: D/W, 3 knobs and 3 buttons per unit, mappable to any parameter
* templates and racks: save and load whole fx setups
* master bus fx on the sum (internal mixer only)
* plugin manager: enable, validate, block / unblock, own plugin folders, install from file
-> [MANUAL 08](MANUAL.md#-08--fx)

## ◆ BROWSER

* two panes side by side or stacked, each with own source, search, sort, filters
* sources: collection, playlists, smartlists, running tracks, history, preparation, music folders, explorer
* favorites bar: 6 slots per pane, each a source or a filter
* sort by up to three columns; columns movable, hideable, saved
* two-line rows: title, artist, comment, tags, label; detail bar below the list
* preview: mini overview of each track in its row, with hotcues and loops
* search: artist, title, comments, label, genre, album, key; accents ignored
* played marks, hide played tracks, reset played state (⌥⌘P)
* inline edit and edit window for metadata, several tracks at once
* analyse from the menu: tempo, grid, key, loudness
* drag tracks onto decks, preparation, playlists and folders
-> [MANUAL 09](MANUAL.md#-09--browser)

## ◆ TAGS + SMARTLISTS + MATCHING

* tags in comment 2, separator configurable; tags travel with the collection
* click a tag = filter, ⌥-click = exclude; several tags = all must match
* tag groups: a single capital letter starts a group (K kick, B bass, H hats)
* role words (BASIS, SYNTH, DRUMS, VOLL, ATMO) filter by role
* group colors come from the waveform colors; TAGS menu shows one column per group
* smartlists: rule editor on artist, bpm, key, tags, dates, plays, loudness and more
* smartlists: all / any rules, sort + limit, live hit count
* ◆ PASST: only tracks that fit the master key and tempo (±4 %)
* match column: pitch in % needed to reach the master tempo; harmony sort
* key colors on the open key wheel: same, ±1, relative, clash
* match reference: audible key of the master, or fixed decks (several possible)
-> [MANUAL 10](MANUAL.md#-10--tags--smartlists) · [MANUAL 09](MANUAL.md#-09--browser)

## ◆ LIBRARY + FILES

* reads the nml collection; writes only when you turn write-back on, with a backup first
* write-back: edits, hotcues, grids and analysis go into the collection, one entry at a time
* write-back waits while the library software is running
* default: collection untouched, all edits in the MINOS-741 folder
* collection check (read only): missing, broken, empty, duplicate and twin files
* duplicate merge: keeps the best entry, merges tags, cues and rating
* music folders: browse folders on disk; files outside the collection load too
* explorer: find folders and audio files on all drives, incl. usb sticks
* cloud folders: online-only status, download on request
* missing tracks: tree entry lists them, can be sent as a playlist to TIDAL
* playlists: own folders, playlists, smartlists; drag to reorder; undo
* export: nml collection, m3u or a folder with the audio files
* decoded track cache, 1-64 GB (default 8)
* backup = copy the MINOS-741 folder
-> [MANUAL 13](MANUAL.md#-13--files--folders) · [MANUAL 09](MANUAL.md#-09--browser)

## ◆ AUDIO EDIT + PREPARE

* cut audio: mark a range on the beat, save as new file, original never changed
* cut IN / OUT: play only part of a file, no new file
* edit list per track: remove, keep, duplicate, mute, move segments, reverse
* RENDER: edit list -> new file with metadata, grid and cues mapped
* tool loops: exactly 2 / 4 / 8 / 16 beats as own file, seamless loop
* prepare row: grid, cut, A-B-A, gain (AMP / NORM to -0.3 dBFS), join, split, render
* join two tracks on the grid, tempo matched within ±0.5 %
* audio-edit mode: work list of new tracks with suggestions and done marks
* export: wav, aiff, lossless m4a, aac 128-320 kbit/s; bit depth; 44.1-96 kHz; dither
* no mp3 export, no mp3 encoder on this system
-> [MANUAL 05](MANUAL.md#-05--waveform--grid) · [MANUAL 09](MANUAL.md#-09--browser)

## ◆ ANALYSIS

* own analysis: bpm, grid, key, loudness, in the background
* bpm range one octave, default 100-200
* key profiles learned from your collection (up to 300 tracks)
* loudness drives auto gain: the louder file plays at the same level
* analysis only writes into the collection when write-back is on
* rip check: finds silence, foreign starts and ends, loops at file edges
* rip check suggests cut points; it never cuts by itself
* grid suspects are flagged; phrase anchor is checked on load
-> [MANUAL 09](MANUAL.md#-09--browser)

## ◆ RECORDING + HISTORY

* ● REC in the top bar: one click starts and stops the set recording
* source: internal master, or the desk input in external mode
* files: lossless m4a, wav or aiff at 24 bit
* tracklist (.txt) and cue sheet (.cue) written next to the recording
* history: a track counts as played after 30 s audible
* history saved per session, archive browsable in the tree
* preparation: list for the next set, archived on start
-> [MANUAL 16](MANUAL.md#-16--recording) · [MANUAL 11](MANUAL.md#-11--history--preparation)

## ◆ CONTROLLERS + KEYS

* Kontrol X1 mk2 in native hid mode, up to two units (left: decks A / C, right: B / D)
* side saved per device serial number; a side change swaps both units at once
* startup show on connect: LED sequence of about 9 s, any input stops it
* pads: hotcues 1-4, shift = delete; FLUX tap switches the pad layer to hotcues 5-8
* loop encoder: turn = loop size, push = loop on / off, shift = beatjump
* browse encoder: selection, push = big browser, shift + push = preview
* fx knobs and buttons per side; touch strip = pitch bend (shift = seek)
* 7-segment displays show the loop size of each side
* every keyboard action can be mapped (⌘, -> KEYBOARD)
* other controllers and midi: not supported yet (see planned)
-> [MANUAL 12](MANUAL.md#-12--keys) · [controllers](controllers.md)

## ◆ TWO MACS

* two macs as one session: they find each other on the network, no setup
* each mac picks its own decks (at most 2) and its own audio interface
* one mac writes to the collection; writing can be handed over
* played marks are shared both ways
* link follows one leading mac; the other follows its tempo and beat
* LIVE keeps the display and the mac awake

## ◆ VIEW + SETTINGS

* view profiles: named layouts (decks, mixer, fx, browser), switch by key
* zoom like a web browser (⌘+ / ⌘- / ⌘0), 50-200 %
* top bar scales 60-130 %; fullscreen hides the toolbar
* compact decks (⌥⌘K): pitch fader, hotcues and grid tools off
* status bar: messages and background jobs; meters for DSP, latency, dropouts, RAM, CPU
* settings (⌘,) with search (⌘F); german and english UI
* help mode: ? in the top bar, rest the mouse on a control for a short explanation
* data folder MINOS-741 next to the collection: settings, session, analyses, edits
-> [MANUAL 03](MANUAL.md#-03--screen)

## ◆ STABILITY

* audio and sync run apart from the ui: a hanging ui does not stop the sound
* ui can hang or restart; the set keeps playing
* audio device gone -> decks keep state; output reopens by itself when it is back
* track files decode in a separate process: a hanging cloud file only blocks its helper
* track without data after 4 s is cancelled (setting 2-15 s); other decks stay untouched
* sleep / wake: output reopens, playing decks keep playing, controllers reconnect
* a stuck parallel worker is skipped; the core falls back to serial
* bad audio blocks are dropped, the deck resets and fades back in
-> [MANUAL 14](MANUAL.md#-14--troubleshooting)

## ◆ PLANNED

from the [roadmap](roadmap.md), not built yet:

* midi controllers and midi learn, user mapping files (1.0)
* midi clock in / out (p2)
* mixer fx, more effects, more eq types (p2 / p3)
* headphone cue in internal mode (p2)
* edit track color (p2)
* freeze / slicer, stem and remix decks, pattern player, live input (p3 / p4)
* timecode / dvs (p4)
* track info panel, layouts and deck sizes (p3)
