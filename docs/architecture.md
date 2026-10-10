# ARCHITECTURE

```
 audio thread (coreaudio)          c++ core MixDSP, atomics only, no locks, no allocations
        ▲
 control thread (200 hz)           deck logic, sync, phase lock, master clock, controller hid, history
        ▲
 ui / main thread (30 hz mirror)   swiftui, browser, settings
```

self test: main thread blocked for 3s -> deck a plays on (3.08 s), deck b follows a tempo change, phase error 0.0000 beats.

## ◆ MODULES

* `MixCore` -> swift, no audio: track model, nml parser, smartlist queries, beatgrid, history, track edits, metadata edits, collection write-back, track overviews
* `MixDSP` -> c++17 realtime core with a plain c api (`MixDSP.h`) and the coreaudio render callback
* `MixEngine` -> swift: device output, routing, decoding, `MixController` (all commands, control thread)
* `MixApp` -> swiftui: decks, mixer, fx, master clock, browser, settings, controller driver, history store

## ◆ AUDIO CORE

one auhal output on the device with all its channels, render callback in c++.

```
track (float, in memory) -> hermite varispeed | time-stretch (keylock / key shift)
  -> flux -> gain -> 3-band eq -> channel filter -> fx 1 -> fx 2 -> fader -> deck pair
master clock -> metronome click -> own pair
```

* tracks are decoded in chunks straight into the deck buffer (float, device rate) -> one copy in memory
* track handoff by generation: the old buffer is freed only after the audio thread confirms it took the new one
* the device rate is never changed
* keylock latency is compensated -> position and seeks point at what you hear
* stopped decks without fx tail cost nothing
* render block runs with denormals flushed to zero (restored afterwards)
* filter frequencies clamped below nyquist (devices at 16-32 khz)
* a deck block with nan / inf is dropped, the deck resets its recursive state (`healDeck`) and fades back in; nan never reaches the device
* hard clip as last stage

plugins (audio units):

```
fx unit × deck -> PluginInstance (swift, control thread) -> MDPlugin (c, AUHost.cpp) -> AudioUnitRender in the render callback
```

* one instance per unit × deck, opened off the control lock on its own queue, then swapped in by an atomic pointer
* the old instance is closed only after the audio thread finished a whole block without it (render counter)
* input -> render callback on the deck buffer, output -> preallocated buffers, error -> signal stays dry
* off = input closed, the tail rings out until 1 s below -100 dB, then the plugin is no longer rendered
* parameters and state (ClassInfo) from the control thread, the plugin window mirrors its changes to the other decks

## ◆ SYNC

* master = master deck or the master clock (MASTER mode)
* tempo follows every tick, phase via a small rate nudge (max 6%)
* hard jump only if the error stays above 0.25 beats for 100 ms
* AUTO mode: clock follows the master deck (metronome, later link)

## ◆ TRACK OVERVIEWS

browser preview column. per track 320 points × 4 bytes (peak, bass / mid / high share) = 1.25 kb, ~1.45 kb on disk with key and stamp.

* `MixCore/TrackOverview.swift` -> `TrackOverview` (reduce waveform blocks to points) + `OverviewStore`: one append-only file `overviews/overviews.bin` (`MOV1`, records `len · key · size · mtime · duration · points`), later records win, rewritten on load when more than half is stale. valid while file size and mtime match, checked once per session per track off the main thread
* `MixEngine/OverviewAnalyzer.swift` -> overview from a file without decoding it into memory: chunked read, same 3-band filters and 300 blocks/s as the deck waveform
* sources: deck load (from `TrackAudio` blocks, ~1 ms) · right click batch · idle job (1 worker, newest first, skips cloud-only files)
* jobs run on own threads (qos utility, max 2), pause while any deck plays or loads (checked between read chunks), cancellable
* drawing: `PreviewSpec` (overview generation, grid with own edits, cues, palette, phrase) -> 400×34 px cgimage rendered off the main thread, `NSCache` (48 mb). a row only hashes its spec and looks the image up, no work per frame
* measured (14k collection, offscreen table, 41 rows per page): page scroll 77 ms without previews, 83 ms with previews from cache, 95 ms cold. one image ~1.4 ms in the background. batch 150–330 tracks/min (2 workers, file cache cold / warm)

## ◆ STATE

`MixController` holds one `MixState` behind a lock. ui and controllers only call commands. the ui pulls a snapshot 30x per second and redraws on change.
