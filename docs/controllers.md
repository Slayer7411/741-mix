# CONTROLLERS

supported: the 2-deck hid controller with vid `0x17cc`, pid `0x1220` (usage page `0xff01`), native hid mode. other dj software has to be closed.

## ◆ SETUP

* two units at the same time, each with a left and a right deck
* fixed side per device: left unit = decks a / c, browser pane left, fx1 (+fx3); right unit = b / d, pane right, fx2 (+fx4)
* the side is saved per serial number (no serial: usb position) in `controller.sides`. first time without an entry: in order of detection, then saved. old deck assignments a / c or b / d count as left / right
* both units never share a side: when the saved side is taken, the second one gets the other side (and keeps it)
* ⌘, -> CONTROLLER: name, serial number and side per device. picking the other side swaps both units at once (decks, browser pane, fx, leds). decks, pane and fx stay changeable per device, a side change resets them to the side's default
* "blink" lights the pads of one unit white
* status bar on connect: `Controller links: A / C`

## ◆ STARTUP SHOW

on every connect (app start, replug, wake) ~8.9 s on all leds of the unit, then the normal state:
* 0-5 s storm: 0-1.2 s dark red embers with denser sparks, 1.2-3.5 s purple chase over the pads and the touch strip with red trails and white sparks in two rounds (second one reversed, faster, more sparks), 3.5-5 s strobe getting denser and whiter
* 5-6.2 s decks of the side: 7 segment displays `-A-` / `-C-` (right unit `-b-` / `-d-`), left pads + left half of the strip purple, right side red, deck buttons lit
* 50 ms black, 6.25-7.35 s white flash (holds)
* 7.35-8.85 s fade from white into the normal state of every led (cosine curve, both reports mixed byte by byte with the normal ones), ready
* colors: 741 red, bone white, purple. brightness max = `led brightness on`
* any input stops it, the input works as usual
* runs on the control queue in the 30 ms led tick, pure generator time -> frame (`LEDShow`)
* ⌘, -> CONTROLLER -> LEDS -> `Startsequenz beim Verbinden` (default on), button `Startsequenz` per device plays it again. a side change shows the decks part
* `MIX741_LEDSHOW=1`: plays it once more 6 s after the start, only with connected units

## ◆ MAPPING

default layout:
* play (shift: cup), sync (shift: master)
* hotcue 1-4 (shift: delete)
* loop encoder: turn = loop size, push = loop on / off, shift + turn = beatjump, shift + push = reloop
* load -> selected track of the own browser pane. a playing deck is locked (load lock), shift + load forces it. ⌘, -> CONTROLLER -> `Shift + LOAD` -> instant double from the deck on the other side instead (load lock applies)
* browse encoder -> selection (shift: x10), push = big browser, shift + push = preview
* fx: d/w knob, knob 1-3, button 1-3 = the unit's quick controls ([manual](MANUAL.md#quick-controls)). default with two or more built-in slots in front: knob 1-3 = main parameter of slot 1-3 (filter cutoff, roll length, else the slot's d/w), button 1-3 = on / off of slot 1-3; otherwise the 3 parameters of slot 1, button 1 = slot 1 on / off
* mode = all slots off (remembers which were on) / back on, shift + mode = next template (group FLT·DLY·REV, filter, delay, reverb, gater, roll, flanger, phaser)
* load -> selected track of the own browser pane
* browse encoder -> selection (shift: x10), push = big browser (or matching on / off, ⌘, -> CONTROLLER), shift + push = preview
* fx: d/w knob, knob 1-3, button 1-3 = the unit's quick controls. default group template: knob 1-3 = filter / delay / reverb amount, button 1-3 = on / off
* mode = all slots off / back on, shift + mode = next template
* off = input closed, echo and reverb ring out
* reverb as only slot: knob 1-3 = size / hp / lp, d/w = send into the reverb
* beat fx as only slot: gater rate / shape / width + mute / trip, roll length / filter / decay + rev, flanger and phaser rate / depth / feedback + freeze / sync (phaser: stages 4 / 8)
* fx assign buttons per side
* touch strip: pitch bend (shift: seek), split left / right side
* 7 segment display: loop size of each side

my custom mappings:
* cue held = flux reverse (shift + cue = normal cue)
* flux tap = pad layer switch: pads 1-4 play hotcue 5-8 (set / jump, shift = delete), pads show the colors of hotcues 5-8 and the flux led stays lit; tap again = back to hotcue 1-4. per side, the layer stays when the pads are used
* shift + flux = tap: tap on the beats, from 4 taps the grid bpm from the mean interval (setting: flux mode on / off instead, flux led half bright while only flux mode is on)
* shift + sync = this deck becomes the tempo master
* flux held + pad 1-4 = hotcue 5-8 only while held (setting: beatjump -1 / +1 on pads 3 / 4 instead), a tap with a pad in between does not switch the layer
* setting "flux button" -> flux mode: old layout, flux tap = flux mode on / off, held = layer as above
* sync held + hotcue 3 / 4 = exactly one beat (one kick, 1/4 bar) back / forward, also with flux held or the pad layer on. inside a loop the loop stays and the position wraps (sync toggles on release if no pad was hit). `MIX741_DEBUG=1` logs each jump: `[jump] deck A: from → to s (reason, ±beats)`

all of it under ⌘, -> controller.

## ◆ HID LAYOUT

input report `0x01` (offsets include the report id):

| byte | bits |
|---|---|
| 0x01-0x08 | fx unit 1: d/w, knob 1-3 (12 bit, little endian) |
| 0x09-0x10 | fx unit 2: same |
| 0x11 | high nibble browse encoder, low nibble left loop encoder (4 bit counters) |
| 0x12 | low nibble right loop encoder |
| 0x13 | fx buttons: 0x80 mode1, 0x40/0x20/0x10 fx1 btn 1-3, 0x08 mode2, 0x04/0x02/0x01 fx2 btn 1-3 |
| 0x14 | 0x80/0x40 left fx assign, 0x20/0x10 right fx assign, 0x08 left load, 0x04 shift, 0x02 right load, 0x01 right loop push |
| 0x15 | right deck: 0x80-0x10 hotcue 1-4, 0x08 flux, 0x04 sync, 0x02 cue, 0x01 play |
| 0x16 | left deck: same |
| 0x17 | 0x02 browse push, 0x01 left loop push |
| 0x1B-0x1C | touch strip, first finger (11 bit): 0 = no touch, 1-0x1C0 left half (deck A/C), 0x1C0-0x240 dead zone in the middle, 0x240-0x400 right half (deck B/D); second finger at 0x1D-0x1E (unused) |

output report `0x80` (leds, 0-127 brightness):

| byte | led |
|---|---|
| 0x01-0x08 | fx unit 1 + 2: mode, button 1-3 |
| 0x09 0x0A / 0x0F 0x10 | fx assign left / right |
| 0x11 / 0x13 | load left / right |
| 0x12 | shift |
| 0x14-0x25 | left pads rgb (0x14, 0x17, 0x20, 0x23) |
| 0x1A-0x2B | right pads rgb (0x1A, 0x1D, 0x26, 0x29) |
| 0x2C 0x2D 0x30 0x31 | left flux, sync, cue, play |
| 0x2E 0x2F 0x32 0x33 | right flux, sync, cue, play |

output report `0x81`: 7 segment displays (left from 0x01, right from 0x19, 3 digits x 8 segments: +0 dot, +1 g, +2 c, +3 b, +4 a, +5 f, +6 e, +7 d) and the touch strip (0x31+, red / blue per segment, 21 pairs as used by the startup show).
