# SETTINGS

everything under ⌘, saved as json in the user defaults (`prefs.v1`).

## ◆ DECKS

* snap (cues, loops) and quant (jumps keep the phase)
* hotcue jump keeps the beat phase
* load position: load cue / grid, track start or hotcue 1
* track end warning (seconds, 0 = off)
* keylock on for the first load, default tempo range (±6 … ±100 %)
* phase lock while synced, sync mode: dynamic / fixed / tempo only, pitch bend amount
* metronome output pair
* default loop size and beatjump size
* history: played after x seconds audible, optional copy into the collection's history folder
* show 4 decks, preview start position in the browser

## ◆ MIXER & FX

* show internal mixer
* headroom internal / external (−3 dB default), auto-gain external, main volume external
* auto-gain from the collection loudness
* eq kill (knob fully left = off)
* crossfader curve: smooth / sharp cut
* channel filter resonance
* show fx units, 2 or 4 units, delay feedback, fx filter resonance

## ◆ DISPLAY

* waveform style: 3-band layers / spectrum / mono
* palette: 741 bone, orange, blue / white, classic
* zoom (seconds per side), minimum height (grows with the window), dim the played part
* beatgrid: on / off, colorful (phrases, bars, beats), phrase length 16 / 32 / 64 / 128 beats, bar numbers
* cue colors: start cue red, cues white, loops green, 1-2 bar loops magenta
* magenta markers every 8 / 16 / 32 bars
* tag separator for comment 2, empty = space
* browser layout, hide the tree while decks are visible
* write browser edits into the collection file (off): backup at most once per hour into `Backup MINOS-741`, not while the library software runs -> [manual](MANUAL.md#-09--browser)
* language: system / english / german (after restart)

## ◆ AUDIO

* output device (the system default or any device, saved by uid)
* sample rate (what the device offers, applies to the device right away, inside minos from the next start) and buffer size
* reconnect -> restarts the output, also via ↻ in the status bar
* mode: internal (mixer in the app) or external (mixing desk)
* internal: which pair the master goes to
* external: one pair per deck, default a 1/2 · b 3/4 · c 5/6 · d 7/8

## ◆ CONTROLLER

* controllers: decks per unit (left / right), browser pane and fx unit per unit, blink to identify
* cue action: flux reverse / cue / reverse
* flux tap toggles flux mode, beatjump size for flux + hotcue 3 / 4
* touch strip: bend or seek, sensitivity
* browse step with shift
* led brightness on / off, cue and loop pad colors
