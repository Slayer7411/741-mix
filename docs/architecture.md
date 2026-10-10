# ARCHITECTURE

same split as traktor -> sound first, ui last.

```
 audio thread (coreaudio, one per deck)      reads sample buffers + a few control values, no locks
        ▲
 control thread (minos741.control, 200 hz)     deck logic, sync, phase lock, x1 hid input + leds, history timing
        ▲
 ui / main thread (30 hz mirror)             swiftui, browser, settings -> may hang, nothing above stops
```

tested: the self test blocks the main thread for 3s -> deck a keeps playing (3.08 s of audio), deck b follows a tempo change and stays in phase (error < 0.01 beats).

## ◆ MODULES

* `MixCore` -> plain swift, no audio: track model, nml parser, smartlist query language, beatgrid math, history read / write
* `MixEngine` -> audio + control: `MixEngine` (graph, routing), `DeckPlayer` (render callback), `MixController` (all deck logic on the control queue), `TrackAudio` (decode + waveform analysis)
* `MixApp` -> swiftui: decks, mixer, fx, browser, settings, x1 driver, history store

## ◆ AUDIO GRAPH

one `AVAudioEngine` per deck -> each deck can go to its own channel pair of the same device (channel map on the output unit). internal mode = all decks on the same pair, coreaudio sums them.

```
source (DeckPlayer) -> varispeed (tempo, keylock off) -> timepitch (tempo + key, keylock on)
  -> eq (low / mid / high, channel filter lp / hp, gain)
  -> fx unit 1 (filter -> delay -> reverb) -> fx unit 2 (same)
  -> channel (fader x crossfader) -> main mixer -> output (channel map)
```

* tracks get fully decoded into memory at the engine rate (about 21 MB per minute per deck at 44.1 khz)
* old buffers get released 0.5s after a swap -> the audio thread never reads freed memory
* the engine respects the device sample rate. it never sets it -> changing the rate of a shared device stops every other output on it
* coreaudio config changes only trigger a re-route if an engine really stopped (not for the notifications our own routing causes)

## ◆ SYNC

* master = explicit master deck, otherwise the first playing deck without sync
* tempo follows the master every tick
* phase: error in beats from both beatgrids -> small rate nudge (max 3%) below 0.2 beats, hard jump above
* beatgrid = first grid marker + bpm from the traktor collection (no own analysis yet)

## ◆ STATE

`MixController` holds one `MixState` struct behind a lock. ui and controllers only call commands (`togglePlay`, `hotcue`, `beatjump` …). the ui pulls a snapshot 30x per second and only redraws when something changed (sync nudge is left out on purpose -> no redraw storm while synced).
