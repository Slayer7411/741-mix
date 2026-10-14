# ROADMAP

■ done · ◧ partly · □ missing · p1 = next

## ◆ DECKS

| feature | | note |
|---|---|---|
| 4 track decks, play / cue / cup, cue hold preview | ■ | |
| hotcues 1-8 (cue / loop), set / jump / delete, keep phase | ■ | colors in settings |
| save hotcues and grid edits | ■ | own file, collection untouched |
| auto loop 1/32-32, loop in / out, reloop, loop move | ■ | |
| beatjump 1/4-64, flux, reverse, flux reverse | ■ | |
| instant doubles, key sync, load lock | ■ | `DBL`, `KEY SYNC`, playing deck takes no track (⌥ / shift forces) |
| loop roll / slip | ■ | ROLL beat fx (deck runs on underneath), flux |
| freeze / slicer | □ p3 | |
| stem decks, remix decks, pattern player, live input | □ p4 | |

## ◆ TEMPO / SYNC / KEY

| feature | | note |
|---|---|---|
| sync + master, phase lock on its own thread | ■ | |
| keylock, key shift ±12, tempo ranges, pitch bend | ■ | |
| master clock: auto / master, tap, metronome | ■ | |
| link, network tempo sync (minos leads tempo and bar) | ■ | |
| midi clock in / out | □ p2 | |
| beatgrid editing (shift, bpm, anchor, reset) | ■ | |
| own bpm / key / grid / loudness analysis | ■ | right click -> `Analysieren`, replaygain loudness, key profiles learned from the collection |

## ◆ MIXER / FX

| feature | | note |
|---|---|---|
| internal mixer: gain, auto-gain, 3-band eq + kill, filter, fader, crossfader + curve | ■ | can be hidden |
| external mixer mode, one usb pair per deck | ■ | |
| headroom per mixer mode, autogain extern | ■ | no limiter |
| level meters | ■ | per deck, both channels, preview pair |
| headphone cue in internal mode | □ p2 | external mode uses the desk |
| more eq types | □ p3 | |
| mixer fx | □ p2 | |
| 2 / 4 fx units with insert slots, channel assign | ■ | up to 6 slots, 7 built-in effects, templates, racks |
| beat fx: gater, roll, flanger, phaser | ■ | master clock grid |
| more effects (ramp delay, slicer …) | □ p2 | |
| effect plugins: audio unit (v2, v3) + VST3 in insert slots | ■ | audio units isolated by default, intel-only isolated |
| VST3 in a helper process (crash isolation) | □ p3 | xpc + shared memory ring, VST3 runs in-process so far |

## ◆ BROWSER / LIBRARY

| feature | | note |
|---|---|---|
| collection, playlists, smartlists, search, sort | ■ | |
| own smartlists (same query syntax) | ■ | |
| dual browser side by side / stacked, role filter | ■ | |
| tag system on comment 2 with separator | ■ | |
| preparation (archived on start, nml) | ■ | |
| history + archive (nml in and out) | ■ | |
| hide / move / save columns | ■ | appkit table, order / widths / hidden per pane |
| harmonic browser: key colors, `Match` column, `◆ PASST` filter | ■ | reference = audible key and tempo of the master |
| preview on an own output pair | ■ | core player, file service, cut aware |
| edit metadata: inline, edit window, several tracks | ■ | own file first, writing the collection only on request (setting) |
| edit track color | □ p2 | |
| cover art, favorites, music folders | ■ | |
| track info panel | □ p3 | |

## ◆ CONTROLLERS / OTHER

| feature | | note |
|---|---|---|
| hid controller native, two units | ■ | |
| midi learn, other controllers | □ p2 | |
| keyboard mapping | ■ | every shortcut configurable (⌘, -> keyboard) |
| mix recording | ■ | internal master or desk input, apple lossless / wav / aiff, tracklist .txt + .cue |
| timecode / dvs | □ p4 | |
| layouts, deck sizes | ◧ p3 | |
| playlist export (nml, m3u, folder) | ■ | |
| buffer / latency settings | ■ | sample rate + buffer (⌘, -> AUDIO), device watch |
| decoding in an own process, track cache | ■ | `minos-files`, a hanging cloud file only blocks the helper |
