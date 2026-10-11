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
* `MixMedia` -> swift, no audio device: decoding, waveform analysis, overviews, phrase anchor, artwork, `.mtrk` track files
* `MixEngine` -> swift: device output, routing, `MixController` (all commands, control thread), file service client
* `MixIPC` -> swift: unix socket channel (framed messages, fd passing), helper spawn / exit watch / kill
* `MixProtocol` -> swift: versioned messages between the processes (file service part)
* `MixFiles` -> `minos-files`, the file service helper (one job per process)
* `LibraryCloud` -> swift, no dependencies: cloud file state, scanner, download scheduler, folder watcher, pin state. later part of the file service
* `MixApp` -> swiftui: decks, mixer, fx, master clock, browser, settings, controller driver, history store
  * browser track list -> appkit table (`TrackTableView.swift`): rows by index from the pane's list, new list = `reloadData`, rows draw their cells (coretext). sort + filter run off the main thread (`BrowserPaneModel.list`), the table takes the result directly, not through a swiftui pass

## ◆ AUDIO CORE

one auhal output on the device with all its channels, render callback in c++.

```
track (float, in memory) -> hermite varispeed | time-stretch (keylock / key shift)
  -> flux -> gain -> 3-band eq -> channel filter -> fx 1 -> fx 2 -> fader -> deck pair
master clock -> metronome click -> own pair
preview track -> linear varispeed -> volume -> preview pair (after main, Preview.cpp / MixDSPPreview.h)
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
* preview: own handoff generation, fades in / out on start, pause, jump and switch, no recursive state, a pair missing on the device = silent

output and device (`CoreAudioOutput`, `MixEngine`, `OutputWatch`):

* start / stop, all listeners and reconnects on one serial device queue (`minos741.device`), never main or audio thread. `apply` from the ui waits on it (sync)
* listeners on the running device: `DeviceIsAlive`, `NominalSampleRate` (debounced 150 ms), `BufferFrameSize`, `ProcessorOverload` (own utility queue). on the system object: `Devices`, `DefaultOutputDevice`. callbacks only read the new value and hand an event to `OutputWatch`
* `OutputWatch` (pure state machine, tests): stopped · running · waiting · sleeping. alive 0 or uid missing from the list -> stop, wait for the same uid (list listener + 100 ms poll) -> reopen by uid (`TranslateUIDToDevice`). rate change -> reopen, `setDeviceRate` nil: the device rate is never set automatically, the core rate stays, auhal resamples. buffer change -> latency / buffer re-read. sleep -> stop, wake -> reopen or wait. a failed reopen keeps waiting
* `running` is set before `AudioOutputUnitStart` (the first callback can come first): buffer / plugin releases wait for the core instead of freeing early
* `ProcessInfo.beginActivity([.userInitiated, .latencyCritical, .idleSystemSleepDisabled])` while running or waiting, ended on stop / sleep
* `MixModel` only mirrors: notices, status line, switch to another device (preferred interface back, following the system default). `NSWorkspace` will sleep / did wake -> `engine.willSleep()` / `didWake()`, `ControllerManager` reopens its hid manager after wake
* keylock / fx state needs no reset on a device rate change: the core runs at its own rate throughout, `healDeck` still catches nan

dsp load (`MixDSPCoreAudio.cpp`):

* render callback: `mach_absolute_time` before and after `mdsp_render` -> `mdsp_load_record(start, end, frames)`
* budget = frames × ticks per frame (set from the engine rate before start). per block: busy and budget summed, peak in per mille (compare-exchange), block over budget -> overload counter. relaxed atomics only, no lock, no allocation; ~0.2 µs per block incl. both clock reads (debug build)
* `mdsp_load_take` swaps the sums to zero -> average and peak per read window. one reader (status bar, 4 hz)
* device overloads: property listener on `kAudioDeviceProcessorOverload`, counted on a utility queue
* latency shown = `kAudioDevicePropertyBufferFrameSize` + `Latency` + `SafetyOffset` + stream latency. keylock lookahead (`mdsp_keylock_latency`, stretch output latency) is pre-read and not added

track load (`MixController.load`):

* through the file service (default, see FILE SERVICE): this process never touches the music path
* in-process (`MIX741_INPROC_FILES=1`, helper missing, helper does not start): file check + decode on a background queue, progress after every chunk (frames, false = cancel)
* watchdog on the control tick (every 0.25 s, not a utility queue: that one is starved under cpu load): no new frames for `loadTimeout` (4 s) -> file service: warning notice, deck keeps loading · in-process: cancel flag, load sequence bumped, deck emptied, notice. a decoder stuck in a read returns later and its result is dropped by the sequence check
* notices (`EngineNotice`: level, key, text, detail) -> `StatusCenter` (main thread, `StatusLog` in MixCore: expiry, dedupe by key, history of 50)

plugins (audio units):
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
* live rule (`PluginSettings.allowInProcess`, default off): third-party audio units always isolated, in-process-only plugins (VST3, own folders) not loaded and not in the menu. on -> per-plugin / default isolation as set
* isolated instance gone (`kAudioComponentInstanceInvalidationNotification`) or 2 s without a rendered block -> its instances are taken out (dry), crash counted in `plugins.json` (once per second and plugin), reload after 2 s, blocked at 3
* render errors keep the signal dry: `failedBlocks` / `failingFrames` (relaxed atomics in `MDPlugin`, written by the audio thread) -> control tick reads them once per second
* audio thread only calls `mdplug_process`. open, reset, state on the plugin queue / ui thread; parameter sets on isolated instances on an own serial queue (a hanging service never holds the control lock), reads wait for that queue first
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

## ◆ WAVEFORM SPECTRUM

* `MixMedia/TrackAudio.swift` -> per block (300/s): peak + 3-band shares (one-pole filters, 3-band layers style, overviews) and, on a second core, `SpectrumAnalyzer`
* `MixMedia/SpectrumAnalyzer.swift` -> fed in chunks (whole deck buffer or read chunks). lows: mono -> 2nd order low pass 1 kHz -> every 10th sample (~4.4 kHz) -> butterworth bands sub 20-60, bass 60-250, low mids 250-1k. highs: 256-point hann fft (5.8 ms) centered on each block -> high mids 1-4k, highs 4-10k, air 10-20k. hold of the highs: share of ±75 ms with highs within 8 dB of the window peak
* `MixCore/WaveSpectrum.swift` -> 8 bytes per block: 6 band levels (0.5 dB steps, 255 = 0 dBFS), hold, spare. `reference(percentile:)` per band, `reduced(to:)` -> n columns (mean energy, mean hold) for overviews / the browser preview
* `MixCore/SpectrumColors.swift` -> color per block: band level minus track reference (95th percentile, kept within -10 / +6 dB of a typical club track), +boost for highs, weight 10^(d / 3.5 dB), mix pulled to full saturation. returns body color, high layer height and color, dominant band
* `MixApp/Waveform.swift` -> chunks of rects per quantized color (8 steps per channel, ~110 paths per 2048 blocks) + high layer, overview columns from mean band energy

## ◆ FILE SERVICE

step (a) of the process split: every syscall on a music path (`stat`, `open`, decoder) runs in a helper process that can be killed. a thread blocked inside a cloud file provider can't be cancelled, a process can.

```
MixController.load -> FileServiceClient.decode (blocking, background queue)
   -> idle helper or posix_spawn minos-files (fd 3 = socketpair, only fds 0-3 inherited)
   -> handshake {service, major, minor, build}
   -> decode {id, path, rate, cache dir}            control plane: json frames over the socket
   <- progress {stage, frames} every 0.25 s
   <- done + fd (SCM_RIGHTS) | failed {code}
   -> mmap read-only, check header, mlock -> TrackAudio over the mapping -> mdsp_set_track
```

* helper: `stat` -> cache key (path, size, mtime ns, rate, decoder version) -> cache hit: header checked, mtime touched, fd back. miss: `SF_DATALESS` -> stage `fetching`, decode + analysis (same code as in-process), write `.mtrk`, fd back
* one job per helper, one helper per load in flight (4 decks load in parallel), up to 2 kept idle, one started ahead
* `check(paths:)`: `stat` without materializing, 2000 paths per job -> local · online only · missing · error. used by the collection load (14,160 paths 73 ms, release). no progress for 5 s -> helper killed, the rest stays unknown (counts as present)
* abort by lack of progress, never by total time: no beat for 3 s -> helper frozen, killed. no new frames for `loadAbortTimeout` (60 s, ⌘, -> AUDIO) -> killed, `keine Audiodaten (Drive antwortet nicht)`. another track for the deck -> old helper killed at once (checked every 0.1 s)
* helper crash (channel eof / exit) -> one retry with a new helper, then error. killed and still alive after 2 s -> counted as zombie
* helper does not start 3 times in a row -> blocked 60 s, loads decode in-process meanwhile (warning). helper missing next to the binary or `MIX741_INPROC_FILES=1` -> in-process, log line `[files]`
* engine dies -> helpers see eof on the channel and `_exit` (also with a job stuck in the provider)
* fault injection in the helper: `MIX741_FAULT=hang-open:<glob>,freeze-open:<glob>,crash-after:<bytes>,slow:<kB/s>,crash-start`
* bundle: `Contents/MacOS/minos-files`, signed first (hardened runtime), then the app. dev: next to `minos741` in `.build/<config>/`

`.mtrk` (`MixMedia/TrackFile.swift`), immutable:

```
0      header 4 kb: 'MTRK', format version, header size, decoder version, rate, frames, blocks, block frames,
       source size + mtime ns, file size, 7 sections (offset, length), path, key, checksum (fnv-1a)
16 kb  L[frames] float32, R[frames] float32, peak / low / mid / high [blocks] float32, spectrum [blocks × 8] u8
       every section 16 kb aligned (page size apple silicon)
```

* written to `<key>.mtrk.tmp-<pid>-<rand>`, `F_BARRIERFSYNC`, `rename`. never modified afterwards
* read: magic, version, checksum, file size == header, layout == expected, key -> otherwise rejected (decoded again)
* `TrackAudio` = read-only view: heap (in-process decode) or mapping. the control thread holds it until `mdsp_track_consumed`, unmapped on a utility queue once the last holder lets go (ui, overview, phrase anchor)
* cache `~/Library/Application Support/MINOS-741/cache/`, excluded from backups. limit ⌘, -> AUDIO (default 8 gb). lru by mtime (touched on every hit), mapped files skipped. eviction only `unlink`s, never truncates -> a mapped file stays readable (no SIGBUS). `*.tmp-*` older than 1 h removed. selftest: own cache in `$TMPDIR`

measured (release, m1 pro, local m4a, 47 / 108 mb decoded): in-process 0.29 / 0.73 s · helper, first load 0.41 / 0.95 s (open 16-33 ms, decode 292 / 742 ms, write 75 / 157 ms) · cache hit 7 / 19 ms incl. mlock · helper start 9-21 ms, first start after a build ~0.5 s · hanging open killed 1.04-1.39 s after a 1 s limit

## ◆ TRACK OVERVIEWS

browser preview column. per track 320 points × 4 bytes (peak, bass / mid / high share) = 1.25 kb, ~1.45 kb on disk with key and stamp.

* `MixCore/TrackOverview.swift` -> `TrackOverview` (reduce waveform blocks to points) + `OverviewStore`: one append-only file `overviews/overviews.bin` (`MOV1`, records `len · key · size · mtime · duration · points`), later records win, rewritten on load when more than half is stale. valid while file size and mtime match, checked once per session per track off the main thread
* `MixMedia/OverviewAnalyzer.swift` -> overview from a file without decoding it into memory: chunked read, same 3-band filters and 300 blocks/s as the deck waveform
* sources: deck load (from `TrackAudio` blocks, ~1 ms) · right click batch · idle job (1 worker, newest first, skips cloud-only files)
* jobs run on own threads (qos utility, max 2), pause while any deck plays or loads (checked between read chunks), cancellable
* drawing: `PreviewSpec` (overview generation, grid with own edits, cues, palette, phrase) -> 400×34 px cgimage rendered off the main thread, `NSCache` (48 mb). a row only hashes its spec and looks the image up, no work per frame
* measured (14k collection, offscreen table, 41 rows per page): page scroll 77 ms without previews, 83 ms with previews from cache, 95 ms cold. one image ~1.4 ms in the background. batch 150–330 tracks/min (2 workers, file cache cold / warm)

## ◆ TAGS

* `MixCore/Tags.swift` -> `Tags.split` (every separator character splits), `Tags.key` (case, accents, width folded), `TagFilter` (include all, exclude any, on keys), `TagIndex` (split once per comment 2 text, cleared when the separators change)
* `MixApp/TagChips.swift` -> list cell = one `AttributedString` (one run per tag with background), no view per chip. clicks: `InlineEditController` hit-tests the x ranges of the chips (`TagChipsText.spans`, same font and size as the table, two-line rows: size + weight from the settings), only fully visible chips, upper half in two-line rows
* measured (14,160 tracks, 378 different comment 2 texts): split all 14.5 ms, filter 2 tags + 1 excluded ~3 ms, paging offscreen ~91 ms per page with chips, same as plain text

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
