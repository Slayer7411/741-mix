# SETTINGS

everything lives under ⌘, and gets saved as json in the user defaults (`prefs.v1`). new fields fall back to their default -> old settings survive updates.

## ◆ DECKS

* quantize -> cues, loops and jumps snap to beats
* hotcue jump keeps the beat phase
* load position: load cue / grid, track start or hotcue 1
* track end warning (seconds, 0 = off)
* keylock on for the first load, default tempo range (±6 … ±100 %)
* phase lock while synced, pitch bend amount
* default loop size and beatjump size
* history: played after x seconds audible, optional copy into traktors history folder
* show 4 decks, preview start position in the browser

## ◆ MIXER & FX

* show internal mixer
* auto-gain from the collection loudness
* eq kill (knob fully left = off)
* crossfader curve: smooth / sharp cut
* channel filter resonance
* show fx units, delay feedback, fx filter resonance

## ◆ DISPLAY

* waveform style: 3-band layers / spectrum / mono
* palette: 741 bone, orange, blue / white, traktor
* zoom (seconds per side), minimum height (grows with the window), dim the played part
* beatgrid: on / off, colorful (phrases, bars, beats), phrase length 16 / 32 / 64 / 128 beats, bar numbers
* cue and loop colors (screen and x1 pads)
* tag separator for comment 2 -> every character splits, e.g. `·` or `·»`. empty = space

## ◆ AUDIO

* output device (the system default or any device, saved by uid)
* mode: internal (mixer in the app) or external (mixing desk)
* internal: which pair the master goes to
* external: one pair per deck, default a 1/2 · b 3/4 · c 5/6 · d 7/8

## ◆ CONTROLLER

* x1 mk2: decks per unit (left / right), blink to identify
* cue action: flux reverse / cue / reverse
* flux tap toggles flux mode, beatjump size for flux + hotcue 3 / 4
* touch strip: bend or seek, sensitivity
* browse step with shift
* led brightness on / off, cue and loop pad colors
