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

* `MixCore` -> swift, no audio: track model, nml parser, smartlist queries, beatgrid, history, track edits, metadata edits, collection write-back
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

## ◆ STATE

`MixController` holds one `MixState` behind a lock. ui and controllers only call commands. the ui pulls a snapshot 30x per second and redraws on change.
