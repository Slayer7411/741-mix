# LIBRARY

## ◆ DUAL BROWSER

* one, two side by side or two stacked browser panes (toolbar)
* every pane has its own tree selection, search, sort, role filter and tags
* left controller drives the left pane, right controller the right one
* space / browse push = big browser
* split line between decks and browser can be dragged

## ◆ FAVORITES

* 6 slots per pane, above the tree and the list header
* slot = source (track collection, preparation, running tracks, history, playlist, smartlist, playlist folder, smartlists 741, music folder) or filter (tags, excluded tags, roles, search)
* click -> source of the pane / filter applied, active filter again -> cleared. red = active
* right click -> `Aktuelle Quelle hier ablegen` · `Aktuellen Filter hier ablegen` · `Umbenennen …` · `Leeren`
* drag a tree entry onto a slot
* ⌃⌥1-6 -> last used pane
* saved per pane in the session. playlists + smartlists by collection uuid, then path · smartlists 741 by id, then name · music folders by path
* target gone after a reload -> slot grey, struck through

## ◆ MUSIC FOLDERS

* tree node MUSIC FOLDERS -> the music library as folders on disk
* click a folder -> its audio files, SUBFOLDERS -> everything below it
* files in the collection: all columns (bpm, key, comment 2 / tags, plays …), matched by path
* files not in the collection: grey, title from the file name (`artist - title`), no grid. load, preview, preparation work anyway
* folders are read in the background when they open, then cached. right click -> rescan
* default folder: deepest folder that holds 90 % of the collection's existing files, e.g. `~/Music/DJ`
* own folders: ⌘, -> BROWSER -> collection -> add folder (the automatic one stays in the list)
* every pane keeps its own folder and the subfolders switch, saved in the session
## ◆ CHECK THE COLLECTION

* BROWSER menu -> `Collection prüfen …` or right click TRACK COLLECTION
* read only: files (missing, permissions, 0 bytes), audio header, duration vs the collection (> 2 s), spelling on disk (case, nfc / nfd), title / artist vs file name, duplicates (same file, same artist + title), analysis (bpm, grid, key, loudness), grid (bpm 60-200, anchor inside the file), playlist entries without a track, files in the music folders without a collection entry
* installer style: progress, current file, log, counters. ABBRECHEN stops at once and keeps the findings
* findings table: filter per check, show in browser / finder, copy path, report as txt or csv
* details: [manual](MANUAL.md#check-the-collection)

## ◆ ANALYSIS

* right click tracks, a playlist, smartlist, playlist folder, music folder, PREPARATION or TRACK COLLECTION -> `Analysieren` (missing values only) or `Neu analysieren` (everything; tracks locked in the collection: missing values only)
* tempo + grid anchor, key (open key like the collection), loudness (auto-gain). own code, offline, deterministic, accelerate only
* same queue and rules as the previews: 2 files at a time, throttled while a deck plays, pauses while a deck loads, status bar `Analyse 12/240 · gedrosselt`, ✕ = cancel
* results in `analysis.json` (MINOS-741 folder), laid over the collection on every load -> list, columns, sorting, smartlists, deck, sync, key readout. purple ✓ = own values. right click -> `Analyse verwerfen`
* files from MUSIC FOLDERS without a collection entry get tempo, grid, key and loudness too -> sync works
* collection file only with `Änderungen in die Collection-Datei schreiben` (⌘, -> BROWSER -> collection): TEMPO, LOUDNESS, MUSICAL_KEY and the grid marker (CUE_V2 TYPE 4) of the analyzed entries, same backup and byte-exact write as the metadata edits
* `Neu analysieren` drops an own grid edit (bpm / anchor) of the track, hotcues stay. a track on a deck keeps its grid until the next load
* method: ~11 kHz mono · spectral flux -> fourier tempogram with harmonic comb (60–200 bpm) -> fine search at the beat frequency -> whole beats between start and end · anchor from the onset envelope folded on the beat (1 ms), phrase start by the phrase anchor logic · chroma against krumhansl / temperley profiles · gated block loudness, `PERCEIVED_DB` = gain to the collection's reference
* 20 tracks of the collection (local files): bpm 18 / 20 within 0.1 (the other two 0.7–1.0 off, old vinyl tracks), key 6 / 20 exact + 2 related, loudness ±1.3 dB (median deviation from the collection's value), grid within 20 ms of the collection's marker 10 / 18, ~1 s per track
* details: [manual](MANUAL.md#analyze)

## ◆ RELOAD

* ↻ / ⌘O: everything heavy runs in the background (parse, file check, own edits, indices, sorting of the lists both panes show), the main thread only takes the result
* unchanged tracks and playlists keep their identity -> the lists do not rebuild when nothing changed
* 14,160 tracks, two panes: longest ui stall 1.3 s -> under 30 ms (unchanged collection), 1.5 -> 0.3 s with changed entries

## ◆ CLOUD LIBRARIES

library in a cloud folder (google drive for desktop, icloud drive, any file provider under `~/Library/CloudStorage`):

* column ☁: ● local · ☁ online only · ↓ downloading (grey = waiting) · ✕ missing · empty = not in a cloud folder
* check = file status only (`SF_DATALESS`), nothing gets downloaded. 14k tracks ~0.1 s. on load, on changes in the folder, every 10 min
* ● LOKAL in the pane header -> local tracks only
* right click tracks, a playlist, smartlist, playlist folder, PREPARATION or TRACK COLLECTION -> `Bereitmachen (herunterladen)`
* SET-CHECK in the pane header -> preparation + the pane's list, everything not local listed, `ALLE HOLEN` fetches it
* keep local while MINOS-741 runs: off / preparation + open playlists + decks (default) / whole library. evicted tracks are fetched again
* 2 downloads at a time, new ones wait while a deck loads, keep local goes last and one at a time, 3 tries, 10 gb stay free
* online-only track into a deck -> download requested at once, status bar message
* quit with open downloads -> handed to the provider, it finishes them without MINOS-741
* always offline: finder -> right click the library folder -> make available offline. ⌘, -> CLOUD shows whether it is set

## ◆ EDIT TRACKS

* inline: click a selected row again or return, tab = next column, esc = cancel
* edit window: right click -> `Bearbeiten …` or ⌘E, also for several tracks at once
* saved in MINOS-741 first, optional write-back into the collection file with backup
* details: [manual](MANUAL.md#-09--browser), [nml files](nml-files.md)

## ◆ ROLE CHIPS

basis · synth · drums · voll · atmo
* filter on the role at the end of comment 2 (`» BASIS` etc.)
* more than one chip = any of them

## ◆ TAGS ON COMMENT 2

comment 2 gets split into tags at a separator:
* default separator is a space
* every character in the setting splits, e.g. `·` or `·»`

example with `·`:

```
K tief kurz · B sub leicht roll · H off » BASIS
-> "K tief kurz", "B sub leicht roll", "H off » BASIS"
```

* "tags ▾" lists all tags of the source with counts
* click = filter, several tags = all must match
* ⌥-click = exclude, none of the excluded tags may be there
* comment 2 column shows the tags as chips -> click / ⌥-click works there too
* whole tags only, case and accents ignored
* active filter in the pane header, ✕ TAGS clears it, kept in the session

## ◆ SMARTLISTS

* all smartlists from the collection work as they are
* own smartlists under "smartlists 741" in the tree -> "+ neue smartlist"
* same syntax as the collection's smartlists, live track count

```
$COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
```

syntax: [nml files](nml-files.md).

## ◆ PREPARATION

* right click a track -> "an preparation anhängen"
* archived and cleared on every start
* archive = playlist nml (`TYPE="LIST"`) in `~/Library/Application Support/MINOS-741/Preparation`

## ◆ RUNNING TRACKS · PLAYED

* RUNNING TRACKS = the tracks loaded on the decks
* column ▶: ✓ = played (same rule as history), stays until right click TRACK COLLECTION -> Reset Played State
* `UNGESPIELT` in the pane header (or ⌘, -> BROWSER -> played tracks): played tracks hidden everywhere except history, running tracks and preparation
* the thin stripe in front = track color from the collection

## ◆ HISTORY

* a track counts as played after 30s audible (setting: ⌘, -> BROWSER -> history & preparation)
* external mixer mode: always audible, the desk decides
* internal mode: only with fader / crossfader open
* written as history nml (`history_2026-10-10-01.nml`, day + session number) with deck, start time and play duration; quitting asks first and writes everything
* saved in `~/Library/Application Support/MINOS-741/History`, optional copy into the collection's history folder
* "history" = current session, "history archiv" = own sessions plus all sessions found in that folder

