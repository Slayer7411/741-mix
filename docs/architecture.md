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
* `LibraryCloud` -> swift, no dependencies: cloud file state, scanner, download scheduler, folder watcher, pin state. later part of the file service
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

dsp load (`MixDSPCoreAudio.cpp`):

* render callback: `mach_absolute_time` before and after `mdsp_render` -> `mdsp_load_record(start, end, frames)`
* budget = frames × ticks per frame (set from the engine rate before start). per block: busy and budget summed, peak in per mille (compare-exchange), block over budget -> overload counter. relaxed atomics only, no lock, no allocation; ~0.2 µs per block incl. both clock reads (debug build)
* `mdsp_load_take` swaps the sums to zero -> average and peak per read window. one reader (status bar, 4 hz)
* device overloads: property listener on `kAudioDeviceProcessorOverload`, counted on a utility queue
* latency shown = `kAudioDevicePropertyBufferFrameSize` + `Latency` + `SafetyOffset` + stream latency. keylock lookahead (`mdsp_keylock_latency`, stretch output latency) is pre-read and not added

track load (`MixController.load`):

* file missing -> error right away
* decode on a background queue, progress after every chunk (frames, false = cancel)
* watchdog every 0.25 s: no new frames for `loadTimeout` (4 s) -> cancel flag, load sequence bumped, deck emptied, notice. a decoder stuck in a read returns later and its result is dropped by the sequence check
* notices (`EngineNotice`: level, key, text, detail) -> `StatusCenter` (main thread, `StatusLog` in MixCore: expiry, dedupe by key, history of 50)

plugins (audio units):

```
fx unit × deck -> PluginInstance (swift, control thread) -> MDPlugin (c, AUHost.cpp) -> AudioUnitRender in the render callback
```

* one instance per unit × deck, opened off the control lock on its own queue, then swapped in by an atomic pointer
* the old instance is closed only after the audio thread finished a whole block without it (render counter)
* input -> render callback on the deck buffer, output -> preallocated buffers, error -> signal stays dry
* off = input closed, the tail rings out until 1 s below -100 dB, then the plugin is no longer rendered
* parameters and state (ClassInfo) from the control thread, the plugin window mirrors its changes to the other decks

plugin list and loading (`PluginCatalog`, `PluginInstaller`, `PluginValidator` in MixEngine):

* list = system registry (`AudioComponentFindNext` over `aufx` / `aumf`) + bundles scanned in the standard folders (source, path) + own folders + `.vst3` (listed only)
* own folders: Info.plist `AudioComponents` (type, subtype, manufacturer, name, version, factoryFunction) -> `CFBundleLoadExecutable` -> `CFBundleGetFunctionPointerForName` -> `AudioComponentRegister`. once per bundle path and process, ids already in the system are not registered twice. a removed folder hides its plugins, they stay registered until restart
* fx menu = enabled and not blocked; a blocked or disabled plugin is never instantiated, also not from the session
* isolated: `AudioComponentInstantiate` with `kAudioComponentInstantiation_LoadOutOfProcess` (v2 and v3) on the plugin queue, waited for (10 s timeout), then `mdplug_wrap` configures it like `mdplug_open`. in-process: `mdplug_open` (`AudioComponentInstanceNew`). both off the audio thread, handed over by the same atomic pointer swap
* isolated instance gone (`kAudioComponentInstanceInvalidationNotification`) -> its instances are taken out, the plugin is blocked, render errors keep the signal dry until then
* isolated plugin window: view controller from the service or the generic view, never the v2 view code in-process
* crash marker: `plugin-opening.json` written before an in-process open (instances, plugin window, own-folder bundle code), removed after. found on start -> plugin (or bundle) blocked
* `auval -v type subtype manu` as a child process, pass = exit 0 + `AU VALIDATION SUCCEEDED`, tail of the log kept per `id@version`
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

## ◆ CLOUD LIBRARY

`LibraryCloud` (file provider folders, e.g. google drive). `CloudLibrary` in MixApp connects it to the collection, decks, browser and status bar.

```
CloudScanner (stat, n workers, timeout) ─┐
CloudWatcher (fsevents, file level) ─────┼─> CloudLibrary (main) -> ☁ column, set-check, status bar
CloudFetcher (tick 0.5 s, serial queue) ─┘        ▲ deck loading = pause, keep-local set
```

* state per file: `stat` with materialization off (`setiopolicy_np` `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`, per thread, restored after) -> `SF_DATALESS` in `st_flags` = online only, `ENOENT` = missing, other errors = unknown. a stat never downloads
* not used: url keys (`ubiquitousItemDownloadingStatus`) -> xpc to the provider per file, 14k tracks 12.9 s parallel / 70 s serial, and seconds behind after a download
* scanner: 4 workers, 2 s per file. a hanging call -> path unknown, worker dropped, new one started; 8 hanging -> run stops, rest unknown
* fetcher: `FileManager.startDownloadingUbiquitousItem` (returns at once, the provider downloads), done = stat shows local. priorities deck > make ready > keep local (one at a time, only when nothing else waits), paused = only deck. timeout max(60 s, size ÷ 256 kb/s), 3 tries with growing pause, free space floor, budget per batch (bytes / seconds)
* watcher: fsevents on the common folder of the cloud paths (hidden provider folders left out), changed paths checked again after 0.5 s. eviction = `IsFile | XattrMod | InodeMetaMod` (0x00019000). full check every 10 min
* pin state: no api for other apps (the provider's finder action). read via `fileproviderctl evaluate <folder>` (~40 ms, undocumented output: `"ACTION_UNPIN" = 1` = pinned, `isRecursivelyDownloaded`), unknown if the format differs
* quit: open requests are sent to the provider, downloads finish without the app (measured: request, process ends, 9.6 mb file local 2.5 s later)
* file service later: same interface (`CloudFileSystem`, `CloudScanner`, `CloudFetcher`), state and events over ipc

measured (14,160 collection paths, 14,153 in google drive, macos 26.7): stat scan 0.02-0.14 s · 3 online-only files (0.3 mb) local after 2.8 s · `fileproviderctl evaluate` 43-49 ms.

## ◆ STATE

`MixController` holds one `MixState` behind a lock. ui and controllers only call commands. the ui pulls a snapshot 30x per second and redraws on change.
