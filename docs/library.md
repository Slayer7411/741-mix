# LIBRARY

## ◆ DUAL BROWSER

* one, two side by side or two stacked browser panes (toolbar)
* every pane has its own tree selection, search, sort, role filter and tags
* left x1 drives the left pane, right x1 the right one
* space / browse push = big browser
* split line between decks and browser can be dragged

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

* all traktor smartlists from the collection work as they are
* own smartlists under "smartlists 741" in the tree -> "+ neue smartlist"
* same syntax as traktor, live track count

```
$COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
```

syntax: [traktor files](traktor-files.md).

## ◆ PREPARATION

* right click a track -> "an preparation anhängen"
* archived and cleared on every start
* archive = traktor playlist nml (`TYPE="LIST"`) in `~/Library/Application Support/MINOS-741/Preparation`

## ◆ RUNNING TRACKS · PLAYED

* RUNNING TRACKS = the tracks loaded on the decks
* column ▶: ✓ = played (same rule as history), stays until right click TRACK COLLECTION -> Reset Played State
* the thin stripe in front = track color from traktor

## ◆ HISTORY

* a track counts as played after 30s audible (setting: ⌘, -> decks)
* external mixer mode: always audible, the desk decides
* internal mode: only with fader / crossfader open
* written as traktor history nml (`history_2026y10m10d_21h05m07s.nml`) with deck, start time and play duration
* saved in `~/Library/Application Support/MINOS-741/History`, optional copy into traktors history folder
* "history" = current session, "history archiv" = own sessions plus all traktor sessions

