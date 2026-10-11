# CHANGELOG

all notable changes. format: [keep a changelog](https://keepachangelog.com), versions: [semver](https://semver.org).
`0.x` -> anything can still change.

## ◆ [UNRELEASED]

### added
* deck header: tags from comment 2 as chips (browser colors) and the comment in grey, one line under the title, too long -> `…`. own row with a fixed height: play / tempo / key changes don't touch it, header layout per change unchanged (0.47 ms, bench). rows `Kommentar` / `Tags (Kommentar 2)`, on by default, old settings load with both on
* compact decks: DECKS menu or ⌥⌘K -> pitch fader, hotcues and grid tools off / on together. without the pitch fader the waveform takes the width. also ⌘, -> DECKS
* edit mode per deck: `EDIT` in the transport row, ⌥⌘E (focused deck) or menu DECKS, off by default, saved in the settings. cut row in place of the loop sizes, grid row shown, waveform keeps its height. switching swaps the rows in place: 11.5 ms median (state bench), the other decks are not touched
* cut, non-destructive: IN HERE / OUT HERE at the play position (nearest beat with QUANT, ⌥-click = exact), CLEAR CUT, start → end · length. handles `IN` / `OUT` in waveform and overview to drag, outside the cut dimmed. the audio file is never changed. saved per track in `edits.json`
* cut in the audio core: nothing outside is audible (3 ms ramp at a cut edge), jumps, seeks, load position, cue, CUP and hotcues land inside, forward play stops at the cut end like at the track end, reverse stops at the cut start, a loop over the end wraps there, beatjump past the end lands on the last whole beat before it. bounds per block from a seqlock pair, no locks. render cpu unchanged (4 decks keylock + fx + plugin, 128 frames: 6.10 % -> 6.05 % of a core). offline tests: into the end, seek outside, loop over the end, reverse at the start, keylock, cut changed while playing
* remaining time and track end warning count to the cut end
* browser `Vorhören` with the cut: starts at the preview share of the cut, stops at the cut end, a cut changed on a deck moves a running preview of that track. preview bands dimmed outside the cut (as the deck), edges marked. playhead in the previewed row, click there jumps (clamped into the cut), status bar shows time left to the cut end / cut length, ✕ stops. preview shot (`MIX741_SHOT=preview:`) with two cut rows and a playhead
* grid row: TAP -> bpm from 4 taps on the beats. a grid set by hand shows red: `GRID` label, anchor flag `G`, `◆` before the tempo in the header
* keys: cut start here, cut end here, grid beat 1 here (assignable, no default)
* zoom like a web browser: ⌘+ / ⌘− / ⌘0 and view menu, 50-200 % in browser steps, saved, step in the status bar, also under ⌘, -> DISPLAY. fonts, controls, waveform marks, canvases and table columns scale, drawn at full resolution, minimum window size × zoom (capped to the screen). toolbar, settings and dialogs stay at 100 %. no extra cost per update at 100 % or 150 % (15 ms both), one step ~0.9 s relayout. offscreen check: `MIX741_SELFTEST=1 MIX741_SHOT=zoom:<folder>`
* readme screenshot offscreen: `MIX741_SELFTEST=1 MIX741_SHOT=window:<png>` -> whole window with title bar and toolbar, 4 decks with local files (master, sync + loop 8, edit + cut), no internal mixer, status as external mixer, preparation + collection side by side, 2000 px wide (`MIX741_SHOT_SIZE`, `MIX741_SHOT_SCALE`). built-in output, silent, nothing written. command in [CONTRIBUTING.md](CONTRIBUTING.md)

### changed
* waveform `3-band layers`: three own amplitudes instead of color shares. bass < 250 Hz at the back, mids 250 Hz-4 kHz, highs > 4 kHz in front, taken from the fine spectrum blocks (no extra analysis: decode + analysis 0.94 s for a 7-minute track before and after, release). rms per band, mids ×1.6, highs ×1.2, curve 0.9 against the strongest band, the strongest band reaches the real peak -> kicks read as wide bass, hats as bright needles between them, mids as their own layer (was: highs ×4 / mids ×2 on single-pole shares, the high layer covered almost everything). overview: same heights, level-weighted mean per column. `spectrum (3 bands)` mixes its colors from the same heights. palettes: darker bass, brighter highs, classic highs light blue. waveform build 0.03 s per track as before, still 3 paths per chunk, nothing more per frame
* ⌘, -> DISPLAY -> `high emphasis` also for 3-band and spectrum (3 bands): highs ×0.5-×2
* grid edits on the deck are stored as full grid (bpm + anchor) and win over collection and own analysis. `Neu analysieren` no longer drops them, only RESET does (RESET = grid from the library, collection or own analysis)
* `edits.json` is written in the background, collected for 0.5 s (was: on the main thread on every change). selftest and benches only read it
* state bench: edit / cut actions, `MIX741_BENCH_EDIT=1`; takes the next track when a deck does not load (cloud file stuck)

### fixed
* bench: `MIX741_BENCH=state` / `play` waited forever when a deck failed to load (4 s limit under load). it picks local files only (cloud probe, no download), allows 15 s per load and stops with the reason
* load: the file check runs on the decoder queue instead of the main thread (in a cloud folder even this check can wait for the provider). a missing file still fails within milliseconds
* browser `Vorhören`: the file opens in the background (an online-only file was downloaded while the main thread waited)
* session restore: a music folder source is checked without materializing the cloud folder
* selftest and benches no longer write audio routing, master volume, column layout, preparation and own smartlists
* keylock: a track stopped when the stretcher's read head reached the end, the last ~0.12 s (lookahead) was never heard. it now stops when the audible position reaches the end
* deck shot (`MIX741_SHOT=deck:`) opened the saved output device; now only a built-in 2-channel device, silent
* english ui: status line (mode `Intern` / `Extern`, `alle→`, audio error, rate until restart) and `PREPARATION ARCHIV` / `HISTORY ARCHIV` in the browser tree stayed german
* core: a stopped deck checked the fx tail through the pointer of a plugin that was swapped out and closed while the unit was not assigned to the deck (read from freed memory on the audio thread, AddressSanitizer). the pointer is now synced before the check
* core: NaN / Inf control values (rate, seek, loop, fx, master, clock) are dropped at the c api instead of sticking in the core (position NaN = silent deck, clock stops). a loop with end <= start is not activated
* plugins: the reset of an audio unit after a NaN block runs on the plugin queue, not under the control lock inside the 200 hz tick (an isolated plugin's reset is an xpc call: 0.06 ms median, 0.23 ms max measured, unbounded when the service hangs)
* engine: spectrum analyzer passed `&array + i` to vDSP (pointer only valid for the `+`, compiler warning); now inside withUnsafeBufferPointer
* load: the 4 s watchdog runs on the control tick instead of a utility queue (starved under cpu load). measured under load 50-124 (16 busy loops + whole test suite): cancel 1.09-1.15 s after a 1 s limit; the timing tests measure the notice time stamp, the test's own polling saw the result 6-17 s late
* auto gain had the sign inverted: quiet tracks got quieter, loud ones louder. the collection's perceived loudness is the gain to apply (measured: −45 dBFS tracks carry +29…+37 dB, a −0.5 dBFS track −28.8 dB)
* analysis: right click tracks or a source (collection, preparation, playlist, smartlist, folder, music folder) -> `Analysieren` (missing values) / `Neu analysieren` (everything, locked tracks only missing). tempo + grid anchor, key (open key), loudness (auto-gain) computed by MINOS-741: spectral flux -> fourier tempogram -> fine search -> whole beats, onset envelope folded on the beat (1 ms), phrase start via the phrase anchor logic, chroma vs krumhansl / temperley, gated block loudness as the collection's gain value
* analysis: same background queue as the previews (2 files, throttled while a deck plays, pause while loading), status bar `Analyse 12/240`, ✕. results in `analysis.json` on top of the collection for list, columns, deck, sync, key readout, purple ✓. `Analyse verwerfen`. loose files from MUSIC FOLDERS get a grid. written into `collection.nml` (TEMPO, LOUDNESS, MUSICAL_KEY, grid cue) only with the write-back setting
* analysis: 20 local tracks of the collection: bpm 18 / 20 within 0.1 (the other two 0.7–1.0 off, old vinyl tracks), key 6 / 20 exact + 2 related, loudness ±1.3 dB (median deviation from the collection's value), grid within 20 ms of the collection's marker 10 / 18, ~1 s per track. tests with click tracks (±0.05 bpm, ±5 ms), chords and sines
* fx mapping: D/W, knobs 1-3 and buttons 1-3 of every unit on any parameter of the loaded effect -> built-in parameters or the full audio unit / VST3 list (unit, range, groups, list entries). right click a knob / button or ⌘, -> MIXER & FX (table per unit, search). buttons toggle switches, step lists, jump continuous ones min / max. remembered per effect / plugin id, the session keeps each unit's mapping. the controller's fx knobs and buttons use the same mapping. labels show the parameter, value with unit on hover / turn
* browser: favorites bar per pane, 6 slots above tree and list. slot = source (collection, preparation, running tracks, history, playlist, smartlist, playlist folder, smartlists 741, music folder) or filter (tags, roles, search). click switches the pane, active filter again clears it, red = active. right click -> put current source / filter here, rename, clear. drag a tree entry onto a slot. ⌃⌥1-6 on the last used pane
* favorites saved per pane in the session: playlists + smartlists by collection uuid, then path, music folders by path. missing target after a reload -> grey, struck through. selftest image `MIX741_SHOT=browser:<png>` also renders the bar filled, narrow and empty
* deck rows on / off: readouts, comment, tags, phase bar, overview, transport, hotcues (with IN / OUT / RE), loop sizes, beatjump, grid tools, pitch fader -> menu DECKS -> ROWS or ⌘, -> DECKS, same order in both
* browser preview, full row: text above the band 12 pt semibold, band dimmed; size, weight and band opacity in ⌘, -> DISPLAY -> preview
* browser: tags in the comment 2 column as chips -> click = filter by that tag, again = off, ⌥-click = exclude. double click on a chip does nothing, click next to the chips selects / edits as before
* browser: active tag filter as chips in the pane header (excluded struck through), click removes one, ✕ TAGS clears all. TAGS ▾ takes ⌥-click too, the smartlist from tags keeps excluded ones (`!%`). whole tags, case and accents ignored. excluded tags saved per pane in the session
* tag chips offscreen: `MIX741_SELFTEST=1 MIX741_SHOT=tags:<folder>` -> image, click checks, paging times
* cloud libraries (file provider folders, e.g. google drive): column ☁ per track (● local · ☁ online only · ↓ downloading · ✕ missing), checked by file status without downloading (14k tracks ~0.1 s), again on changes in the folder (fsevents) and every 10 min
* cloud: right click tracks or a source -> `Bereitmachen (herunterladen)` with progress and cancel in the status bar. 2 at a time, new downloads wait while a deck loads, 3 tries, timeout by size, 10 gb stay free, each file confirmed local
* cloud: SET-CHECK in the browser header -> preparation + the pane's list, everything not local listed, one click fetches it. ● LOKAL filter
* cloud: keep local while running (⌘, -> CLOUD): off / preparation + open playlists + decks (default) / whole library, evicted tracks are fetched again
* cloud: online-only track into a deck -> download requested at once, message. quit with open downloads -> handed to the provider, it finishes them without MINOS-741
* cloud: ⌘, -> CLOUD shows whether the library folder is available offline at the provider, SHOW IN FINDER + how to pin it
* new module `LibraryCloud` with tests (classifier, scanner timeouts, scheduler). selftest image `MIX741_SHOT=cloud:<folder>`
* status bar: one or two line messages (error red, warning gold, info purple, done bone), info 4 s, done 3 s, warning 8 s, errors stay until clicked. same key replaces in place (progress). click -> last 50 with time. messages from loading, phrase anchor, plugins, collection load / write-back, metadata save, export, played reset
* status bar meters: DSP load (render time ÷ block duration, peak hold, red above 70 %), output latency + buffer + rate, dropouts (own over-budget blocks + device overload reports, click resets), memory, process cpu. 4 hz, drawn outside the swiftui layout. ⌘, -> DISPLAY -> status bar
* track load: missing file fails at once, no audio data for 4 s cancels the load (setting 2-15 s), unreadable files fail with the reason. the deck stays empty, other decks untouched, message `Track nicht ladbar (4 s): artist – title · reason`
* failed load shows a skull in the waveform for 5 s, empty decks show the lobster
* waveform: `spectrum fine (6 bands)` -> new default of the spectrum style. per block (3.3 ms) sub 20-60 Hz, bass 60-250 Hz, low mids 250 Hz-1 kHz, high mids 1-4 kHz, highs 4-10 kHz, air 10-20 kHz + how long the highs hold (~150 ms window). colors: sub orange, bass / kick red, mids green, high mids yellow-green, short highs (closed hats) blue, held highs (open hats, ride) light blue and brighter, highs also as a layer in the middle so hats stay visible next to kick and bass. every band is normalized against the track's own level -> closed -> open hats, drums coming in and breakdowns stand out. height = real level as before. old look: `spectrum fine, no high layer` / `spectrum (3 bands)`
* settings: DISPLAY -> waveform -> `high emphasis` (0-2, lifts hats up to 10 dB in the color mix), color legend below. palette applies to 3-band, spectrum (3 bands) and mono
* browser preview: mode `Ganze Zeile (zweizeilig)`, new default -> rows twice as high, text on top, the overview as one band across the full row width underneath (continuous over all columns, drawn per visible row). own column / behind the title stay. paging through 14,160 tracks offscreen: median 62 ms per page from the cache (~29 rows), own column 89 ms, off 82 ms (~41 rows) -> per row the same as without preview
* settings: PLUGINS tab -> every effect plugin with manufacturer, version, AUv2 / AUv3 / VST3, source and status, search, per plugin on / off for the fx menu
* plugins: own plugin folders -> `.component` bundles are loaded and registered for MINOS-741 only. PLUGIN INSTALLIEREN … copies bundles (also from folders or `.zip`) to `~/Library/Audio/Plug-Ins/Components`, asks before replacing another version and before removing the download quarantine flag
* plugins: validation with apple's `auval` (single or all, progress, cancel), pass / fail and log tail cached per plugin + version
* plugins: third-party plugins load isolated in a system service by default (per plugin: isolated / in-process). a crash there blocks the plugin and leaves the unit dry, the set plays on. AUMatrixReverb at 512 frames: no added latency, ~0.01-0.02 ms more per block
* plugins: crash marker -> a plugin that took MINOS-741 down while opening is blocked on the next start, also when a session wants it. unblock in the PLUGINS tab
* plugins: VST3 effects in the fx single mode next to audio units -> every effect class of a `.vst3` bundle (vst3 folders, own folders) in the fx menu with a small `VST3`, knobs 1-3, D/W, ON with spillover, EDIT with the plugin's own view (or sliders), state saved with the session, master clock tempo goes to the plugin. runs in-process (`läuft im prozess` in the PLUGINS tab) with crash marker, latency reported but not compensated
* plugins: PLUGIN INSTALLIEREN … takes `.vst3` too -> `~/Library/Audio/Plug-Ins/VST3`. PRÜFEN for VST3 = self-check in its own process (load, 1 s noise, state, unload)
* PLUGINS tab offscreen without audio device or controllers: `MIX741_SELFTEST=1 MIX741_SHOT=plugins:<folder>` (+ `MIX741_SHOT_PLUGINS=<plugin folder>`), safe while MINOS-741 runs
* plugins: a deck with nan resets its plugin too (skipped until reset), plugin tail time is honored (max 30 s)
* VST 3 SDK 3.8.1 (hosting part, MIT) in `Sources/VST3SDK`, notices in `THIRD-PARTY-NOTICES.md` (also in the app bundle). VST is a registered trademark of Steinberg Media Technologies GmbH
* controller: flux = pad layer switch. tap -> pads 1-4 play hotcues 5-8 (set / jump, shift = delete, pad colors of 5-8, flux led lit), tap again -> back to 1-4, per side. shift + flux = flux mode, held = layer only while held. setting "flux button": switch pad layer (default) / flux mode (old layout)
* loop snap (with SNAP): LOOP / LOOP IN takes a stored loop cue starting up to 1 bar ahead or just passed (start + length), else the nearest 4-bar boundary within 1 beat, else the beat snap. never jumps, the playhead runs into the loop. settings under DECKS -> loops & beatjump (both on, window 4 beats, tolerance 1 beat)
* browser: PREVIEW column -> mini overview per track: 3-band waveform scaled per track, phrase bands, lines every 16 / 32 bars, hotcues, start cue, own grid edits. tracks without overview show grid + cues. setting: own column / behind the title (25 %) / off
* previews come from deck loads (free), right click a source -> `Vorschauen berechnen`, and a background job: rows on screen first, then the newest tracks. setting `immer (gedrosselt)` (default) / `nur wenn kein Deck spielt` / `aus`. status bar `Vorschauen 1.234 / 14.160 · gedrosselt`, ✕. cache `overviews/overviews.bin`, ~1.5 kb per track, renewed when the file changes
* cover art: square cover left of the title in each deck header, preview of the selected track below the browser tree, optional `Cover` column in the list (hidden by default). source: embedded picture (mp3, m4a, flac), else `cover` / `folder` / `front` .jpg / .png in the track's folder. read and scaled in the background, thumbnails cached in `~/Library/Caches/MINOS-741/artwork`, list rows load only while visible. settings: ⌘, -> DISPLAY -> cover
* collection check: BROWSER menu -> `Collection prüfen …` or right click TRACK COLLECTION. read only, in the background, 6 files at a time: missing / unreadable / empty files, audio header, duration vs the collection, case and unicode spelling on disk, title / artist vs file name, duplicates, missing analysis, grid sanity, playlist entries without a track, files in the music folders without a collection entry. window like an old installer: progress with time left, current file, rattling log (last 2000 lines), counters per check, ABBRECHEN stops at once and keeps the findings, then a findings table (filter, show in browser / finder, copy path) and a txt / csv report. settings: check on start (off), scan music folders (on). 14,160 tracks: ~5 s. `MIX741_CHECK=1` (selftest) checks without a window, `MIX741_SHOT=consistency:<png>` renders the window
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
* browser with 4 decks playing (two panes, 14,160 tracks, time until the main thread is free, median): sort column 2.1 s -> 0.31 s, playlist ⇄ collection 2.4 s -> 0.26 s, role / tag filter 0.43 s -> 0.26 s, add to preparation 1.4 s -> 7 ms, search update 0.27 s -> 0.24 s. `MIX741_BENCH=browser`
* browser: lists are sorted with the text keys bridged once per track instead of per comparison, same order (14k tracks by title 850 -> 80 ms, by key 815 -> 45 ms)
* browser: a big list change (source, sort, filter, search) builds the table anew instead of diffing every row (myers diff over 14k rows: up to 2.5 s); small changes (new values, a few tracks added / removed) keep table and scroll position. keyboard focus moves to the new table
* browser: preparation and own smartlists count their changes separately -> adding to the preparation no longer re-sorts every pane
* browser search: the list follows 0.15 s after the last keystroke, empty and ⏎ at once -> typing a word at 10 keys/s = 1 list update instead of 4-6, done after 1.0 s instead of 1.7-5 s
* browser preview full row: the bands are layers composited by core animation instead of drawn on the cpu on every scroll step and list change (scrolling with 4 decks: gaps > 16 ms 45 -> 17, longest 90 -> 31 ms)
* analysis: while a deck plays, results go into the lists at the end of the batch, when no deck plays or after 30 s (was every 0.3 s at up to 1.8 s main thread each with two collection panes)
* ui: a state change costs a fraction -> views read only the part of the state they show, every deck, deck row and the master clock controls lay out in their own hosting view, the window min size no longer measures the content. button press to main thread free (4 decks, two browsers, no mixer, bench): median 87.6 -> 5-7 ms, p95 182 -> 12-18 ms, play 181 -> 12-18 ms. `MIX741_BENCH=state` measures it offscreen on a built-in output
* waveform scrolls evenly: the playhead runs on between audio blocks (the core reports once per block) -> at 120 hz no standing frames (28 % before), steps of 1-2 px instead of 0-3 px. `MIX741_BENCH=play` measures main thread load and steps per frame
* master clock: MAIN only shows where it acts -> internal mode or `main volume also in external mode`
* deck: the selected loop size is purple, red stays for LOOP on / off
* fx: the unit's D/W acts only while a control sits on it (default: D/W knob) -> D/W on a plugin's mix runs the unit fully wet. single delay RATE takes the nearest of the 6 beat values
* controller: sync held + pad 3 / 4 jumps one beat (one kick) instead of one bar; inside a loop the loop stays and the position wraps
* plugin windows stay above the MINOS windows (also in full screen) and hide while another app is active
* browser preview: strong 3-band colors (red = bass, green = mids / synths, blue = highs / drums), weighted against a typical track and saturated -> bass-heavy, synth-heavy and hat-heavy tracks tell apart at a glance. height from peak + bass, breaks clearly lower, thin bright line at big energy jumps (drops), grid fainter behind the waveform. setting preview colors: spectrum (default) / like the waveform (old look)
* reload ↻ / ⌘O no longer freezes the ui: parse, file check, own edits, indices and the sorting of the lists both panes show run in the background, the main thread only takes over the result. unchanged tracks keep their storage and the playlist tree keeps its node ids, so lists and tree see no change when nothing changed. longest main-thread gap on reload (14,160 tracks, two panes) 1.3 s -> 26 ms with an unchanged collection, 1.5 -> 0.3 s with changed entries; first load 2.1 -> 0.9 s. control thread and audio unaffected. `MIX741_BENCH=reload` (selftest) measures it offscreen
* deck: hotcues, loop sizes 1/32 … 32 and beatjump sizes 1/4 … 64 in three full-width rows, the selected loop size purple and beatjump size red (follow the controller too), LOOP = on / off, white / yellow pads with dark numbers. `MIX741_SHOT=deck:<png>` (selftest only) renders a deck offscreen
* settings window redone: sidebar instead of tabs, resizable (min 720 × 520), `◆` section headings, fixed label column, square toggles, slider values with units, one block per controller; selftest renders it offscreen (`MIX741_SHOT=settings:<folder>`)
* big browser ⇄ decks (space / browse push) faster: hidden decks keep their size (no new deck layout, no new waveform tiles), the playlist tree stays in its split at width 0 instead of being removed and re-inserted -> back to decks 939 -> 194 ms, to big browser 328 -> 266 ms (2 browsers side by side, tree only in big browser, 4 decks), 145 / 144 -> 98 / 107 ms with one browser. `MIX741_DEBUG=1` logs `[toggle]` (switch to next frame), `MIX741_BENCH=toggle` measures offscreen without a window
* reverb rebuilt for big washes: 4-stage diffuser + 16-line feedback delay network (hadamard mix, slowly modulated lines, high-shelf damping in the loop) -> dense from the first ms, wide (tail l/r correlation ~0), no metallic ringing. RT60 by size 0 · 0.5 · 0.6 · 0.9 · 1: 0.8 · 1.5 · 1.9 · 5.3 · 13 s -> 0.3 · 3.6 · 5.6 · 22 · ~170 s (near freeze at the top)
* waveform: markers slightly stronger -> loop frame 1.5 pt + denser tint, play head, cues, phrases, anchor and 8/16/32 markers +0.5 pt, beat lines on whole pixels, ruler ticks, caps and bar numbers brighter. check without a window: selftest + `MIX741_SHOT=wave:<png>`
* reverb level: no fixed +10 dB boost in single mode anymore. full d/w on pink noise: track + reverb 4.2× -> 1.2× the dry level (reverb alone +12 dB -> −4 dB), group mode 1.8× -> 1.2×
* reverb tone: the highs stay in the tail -> airy hiss instead of a dull hum. late tail on white noise: share > 4 kHz −48 -> −2 dB, spectral flatness 0.29 -> 0.92, largest peak over the local median 10.6 -> 3.4 dB (pure noise 1.6 dB)
* reverb brightness: high decay 35 … 90 % of the tail, low cut before the reverb 150 … 400 Hz, high shelf −4 … +6 dB from 7 kHz. default 0.4 -> 0.6, an untouched 0.4 moves to 0.6 once
* reverb level at engage stays: full d/w on pink noise 1.18× dry, two techno tracks 1.03× / 1.08×, single mode hp 0 … 0.9 1.02 … 1.45× (was up to 2.33×). tail 0.5–2.5 s after the stop −35 -> −21 dB re dry (size 0.6). cpu 36 -> 53 µs per deck and 512-frame block
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
* browser: crash right after the collection loaded with full row preview (table cells without the model in their environment)
* controller: sync held + pad 3 / 4 is always exactly one bar (4 beats), also with flux held or the pad layer on; a synced deck stays in phase, inside a loop the position wraps. releasing flux after this combo no longer switches the pad layer. `MIX741_DEBUG=1` logs every jump of a deck: `[jump] deck A: 10.500 → 12.500 s (bar jump +1, +4.00 beats)`
* browser preview: the background job only ran while no deck played or loaded, so in a set previews only appeared after loading a track. now it also runs while decks play, throttled: one file at a time, half the cpu time, 1 s between files, ~15 tracks / min; full speed when no deck plays. it waits while a deck loads and 4 s after. offline bench, 4 decks keylock + fx at 256 frames: block p99 921 µs without, 908 µs with the job, no missed deadlines, control tick jitter unchanged
* browser preview: rows on screen without an overview are computed first
* browser preview: files that only exist in the cloud are counted in the status bar (`12 nur online – Rechtsklick lädt`) instead of being skipped silently. the status bar shows progress while paused too
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
