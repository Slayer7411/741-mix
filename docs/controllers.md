# CONTROLLERS

supported: the 2-deck hid controller with vid `0x17cc`, pid `0x1220` (usage page `0xff01`), native hid mode. other dj software has to be closed.

## ◆ SETUP

* two units at the same time, each with a left and a right deck
* default: first unit (usb position) = a / d, second = c / b -> change per device under ⌘, -> controller
* "blink" lights the pads of one unit white

## ◆ MAPPING

default layout:
* play (shift: cup), sync (shift: master)
* hotcue 1-4 (shift: delete)
* loop encoder: turn = loop size, push = loop on / off, shift + turn = beatjump, shift + push = reloop
* load -> selected track of the own browser pane
* browse encoder -> selection (shift: x10), push = big browser, shift + push = preview
* fx: d/w knob, knob 1-3 = filter / delay / reverb amount, button 1-3 = on / off
* mode = fx on / off (group: remembers which slots were on), shift + mode = next effect (single) or next delay time (group)
* off = input closed, echo and reverb ring out
* reverb (single): knob 1-3 = size / hp / lp, d/w = send into the reverb
* fx assign buttons per side
* touch strip: pitch bend (shift: seek), split left / right side
* 7 segment display: loop size of each side

my custom mappings:
* cue held = flux reverse (shift + cue = normal cue)
* flux held + pad 1-4 = hotcue 5-8: set / jump, shift = delete, pads show the colors of hotcues 5-8 while flux is held (setting: beatjump -1 / +1 on pads 3 / 4 instead)
* flux tap = flux mode on / off
* sync held + hotcue 3 / 4 = one bar back / forward, inside a loop the loop stays and the position wraps (sync toggles on release if no pad was hit)

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
| 0x1B-0x1C | touch strip position (11 bit, 0 = no touch) |

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

output report `0x81`: 7 segment displays (left from 0x01, right from 0x19, 3 digits x 8 segments) and the touch strip (0x31+, red / blue per segment).
