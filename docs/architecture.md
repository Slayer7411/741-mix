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

plugins (audio units, VST3):

```
fx unit × deck -> PluginInstance (swift, control thread) -> MDPlugin (c++, Plugin.cpp) -> AUHost.cpp   -> AudioUnitRender
                                                                                    -> VST3Host.cpp -> IAudioProcessor::process
```

* `MDPlugin` = small c++ base (`PluginBackend.h`): `process` / `reset` + type tag, tail length, tempo + beat of the master clock per block. the core (`PluginSlot`) only sees `mdplug_process`, handoff and spillover are the same for both formats

* one instance per unit × deck, opened off the control lock on its own queue, then swapped in by an atomic pointer
* the old instance is closed only after the audio thread finished a whole block without it (render counter)
* input -> render callback on the deck buffer, output -> preallocated buffers, error -> signal stays dry
* off = input closed, the tail rings out until 1 s below -100 dB (or the plugin's own tail time, max 30 s), then the plugin is no longer rendered
* parameters and state (ClassInfo) from the control thread, the plugin window mirrors its changes to the other decks
* nan in a deck (`healDeck`) -> the slot sets `resetPending`, the plugin is skipped (dry) until the control tick resets it (`mdplug_reset`, VST3 on the ui thread) and clears the flag

VST3 (`Sources/VST3SDK` = hosting part of the VST 3 SDK 3.8.1, MIT, own SwiftPM target, `module_mac.mm` as objective-c++ with arc):

```
.vst3 bundle -> VST3::Hosting::Module (CFBundle, bundleEntry, GetPluginFactory; kept loaded per path)
             -> class "Audio Module Class" + sub category Fx -> IComponent (initialize with the host context)
             -> IEditController (same object or own class) -> ConnectionProxy both ways -> setComponentState
             -> setBusArrangements (main in / out stereo, other buses off) -> setupProcessing (realtime, 32 bit)
             -> setActive -> setProcessing
```

* every sdk call marked "ui thread" runs on one thread (`VST3Thread`: main thread in the app, the calling thread in tests and the `--vst3-check` child): open, close, state, controller, view, reset
* audio thread: input into preallocated bus buffers (mono bus = mid), parameter changes from a lock-free ring (several writers, one reader) into preallocated `ParameterChanges` queues (latest value per parameter at offset 0), empty event lists, `ProcessContext` with sample position + master clock tempo, `process`, output back (silence flags honored). no allocation, no locks
* `busy` flag: reset / state / reload take the processor for a moment (cas 0 -> 2), the audio thread never waits, it skips that block (dry)
* knobs -> `mdvst3_param_send` (processor, right away) + `setParamNormalized` (controller, ui thread). values are mirrored in swift, so the control thread never asks the controller
* plugin view edits: `IComponentHandler::performEdit` -> ring + listener -> other decks + knobs; `restartComponent` -> latency / all values re-read
* state = `M7V3` · component state · controller state (little endian lengths), set: component, `setComponentState`, controller, then all values sent to the processor
* editor: `createView(kEditor)` -> `attached(NSView)` in the plugin window, `IPlugFrame::resizeView` resizes the window, window resize -> `checkSizeConstraint` + `onSize`. no view -> sliders per parameter
* latency reported, not compensated. no isolation: apple's out-of-process service is audio unit only

plugin list and loading (`PluginCatalog`, `PluginInstaller`, `PluginValidator` in MixEngine):

* list = system registry (`AudioComponentFindNext` over `aufx` / `aumf`) + bundles scanned in the standard folders (source, path) + own folders + `.vst3` effect classes (`moduleinfo.json`, else the module is loaded, crash marker `bundle:<path>`), id `vst3:<class id>`
* own folders: Info.plist `AudioComponents` (type, subtype, manufacturer, name, version, factoryFunction) -> `CFBundleLoadExecutable` -> `CFBundleGetFunctionPointerForName` -> `AudioComponentRegister`. once per bundle path and process, ids already in the system are not registered twice. a removed folder hides its plugins, they stay registered until restart
* fx menu = enabled and not blocked; a blocked or disabled plugin is never instantiated, also not from the session
* isolated: `AudioComponentInstantiate` with `kAudioComponentInstantiation_LoadOutOfProcess` (v2 and v3) on the plugin queue, waited for (10 s timeout), then `mdplug_wrap` configures it like `mdplug_open`. in-process: `mdplug_open` (`AudioComponentInstanceNew`). both off the audio thread, handed over by the same atomic pointer swap
* isolated instance gone (`kAudioComponentInstanceInvalidationNotification`) -> its instances are taken out, the plugin is blocked, render errors keep the signal dry until then
* isolated plugin window: view controller from the service or the generic view, never the v2 view code in-process
* crash marker: `plugin-opening.json` written before an in-process open (instances, plugin window, own-folder bundle code), removed after. found on start -> plugin (or bundle) blocked
* `auval -v type subtype manu` as a child process, pass = exit 0 + `AU VALIDATION SUCCEEDED`, tail of the log kept per `id@version`
* VST3 self-check: the app itself as child process (`MINOS-741 --vst3-check <bundle> <class id>`): open, 1 s noise in 512 blocks, state read + set, close. pass = exit 0 (opened, everything finite)
* tests build the sdk sample `again_sampleaccurate` (`scripts/build-vst3-fixture.sh`, sources in `Tests/Fixtures/VST3Plugin`) into a temp folder, never into `~/Library`
* install: copy next to the target, then swap (`replaceItemAt`), quarantine (`com.apple.quarantine`) removed only after asking

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
