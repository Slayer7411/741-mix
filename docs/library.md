# LIBRARY

## ◆ DUAL BROWSER

* one, two side by side or two stacked browser panes (toolbar)
* every pane has its own tree selection, search, sort, role filter and tags
* left controller drives the left pane, right controller the right one
* space / browse push = big browser
* split line between decks and browser can be dragged

## ◆ MUSIC FOLDERS

* tree node MUSIC FOLDERS -> the music library as folders on disk
* click a folder -> its audio files, SUBFOLDERS -> everything below it
* files in the collection: all columns (bpm, key, comment 2 / tags, plays …), matched by path
* files not in the collection: grey, title from the file name (`artist - title`), no grid. load, preview, preparation work anyway
* folders are read in the background when they open, then cached. right click -> rescan
* default folder: deepest folder that holds 90 % of the collection's existing files, e.g. `~/Music/DJ`
* own folders: ⌘, -> DISPLAY -> browser -> add folder (the automatic one stays in the list)
* every pane keeps its own folder and the subfolders switch, saved in the session
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
* the thin stripe in front = track color from the collection

## ◆ HISTORY

* a track counts as played after 30s audible (setting: ⌘, -> decks)
* external mixer mode: always audible, the desk decides
* internal mode: only with fader / crossfader open
* written as history nml (`history_2026-10-10-01.nml`, day + session number) with deck, start time and play duration; quitting asks first and writes everything
* saved in `~/Library/Application Support/MINOS-741/History`, optional copy into the collection's history folder
* "history" = current session, "history archiv" = own sessions plus all sessions found in that folder

