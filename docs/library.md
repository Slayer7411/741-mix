# LIBRARY

the browser is the part i care most about -> built around how i prepare and play sets.

## ◆ DUAL BROWSER

* one, two side by side or two stacked browser panes (toolbar)
* every pane has its own tree selection, search, sort, role filter and tags
* e.g. "basis" tracks left, "layer" / tools right
* the last pane you clicked is the target for the x1 browse encoder and load buttons
* the line between decks and browser can be dragged -> height gets saved

## ◆ ROLE CHIPS

basis · synth · drums · voll · atmo
* filter on the role at the end of comment 2 (`» BASIS` etc.)
* more than one chip = any of them

## ◆ TAGS ON COMMENT 2

comment 2 gets split into tags at a separator:
* default separator is a space
* every character in the setting splits -> e.g. `·` or `·»`
* setting: ⌘, -> display -> tags (comment 2)

example with `·`:

```
K tief kurz · B sub leicht roll · H off » BASIS
-> "K tief kurz", "B sub leicht roll", "H off » BASIS"
```

* "tags ▾" in the pane header lists all tags of the current source with counts
* click = filter, more than one tag = all must match
* active tags show up as chips next to it, click removes them

## ◆ SMARTLISTS

* all traktor smartlists from the collection work as they are
* own smartlists under "smartlists 741" in the tree -> "+ neue smartlist"
* editor with name and rule, same syntax as traktor, live track count and parse errors
* right click -> edit / delete
* saved in the user defaults

```
$COMMENT2 % "BASIS" & $BPM >= 128 & $IMPORTDATE >= MONTHS_AGO(6)
```

syntax details in [traktor files](traktor-files.md).

## ◆ PREPARATION

* right click a track -> "an preparation anhängen"
* the list survives a crash or quit
* on the next start it gets archived and cleared
* archive = traktor playlist nml (`TYPE="LIST"`) in `~/Library/Application Support/MINOS-741/Preparation`
* shows up under "preparation archiv" in the tree -> import into traktor via playlist import

## ◆ HISTORY

* a track counts as played after 30s audible (setting: ⌘, -> decks)
* external mixer mode: always audible, the desk decides
* internal mode: only with fader / crossfader open
* written as traktor history nml (`history_2026y10m10d_21h05m07s.nml`) with deck, start time and play duration
* the collection entries get copied 1:1 -> cues, tags and audio id stay intact
* saved in `~/Library/Application Support/MINOS-741/History`, optional copy into traktors history folder
* "history" = current session, "history archiv" = own sessions plus all traktor sessions
* history view: start, deck, artist, title, bpm, key, duration -> double click loads into the focused deck
