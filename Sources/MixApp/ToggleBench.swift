import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine
import LibraryCloud

/// MIX741_DEBUG=1: Zeit vom Umschalten Browser groß/klein bis zum nächsten Display-Link-Takt (erstes neues Bild)
@MainActor
enum ToggleProbe {
    private static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1"
    private static var t0: CFTimeInterval = 0
    private static var big = false
    private static var link: CADisplayLink?

    static func toggled(_ maximized: Bool) {
        guard debug, let screen = NSScreen.main else { return }
        t0 = CACurrentMediaTime()
        big = maximized
        link?.invalidate()
        let l = screen.displayLink(target: Tick.shared, selector: #selector(Tick.fire))
        l.add(to: .main, forMode: .common)
        link = l
    }

    final class Tick: NSObject {
        static let shared = Tick()
        @objc func fire() {
            MainActor.assumeIsolated {
                print(String(format: "[toggle] %@: %.1f ms", ToggleProbe.big ? "browser groß" : "decks", (CACurrentMediaTime() - ToggleProbe.t0) * 1000))
                fflush(stdout)
                ToggleProbe.link?.invalidate()
                ToggleProbe.link = nil
            }
        }
    }
}

/// MIX741_BENCH=toggle: Umschalten offscreen messen. Oberfläche in einem Fenster, das nie gezeigt wird
/// (kein Dock-Symbol), 4 Decks geladen, Ausgabe stumm auf ein eingebautes Gerät; misst Layout + Übergabe an Core Animation je Umschalten.
@MainActor
enum ToggleBench {
    /// toggle: Browser groß/klein · state: Zustandsänderungen an Deck A · play: Hauptthread-Last bei laufenden Decks ·
    /// browser: Suche, Tippen, Filter, Sortierung, Quelle, Scrollen, Laden, Analyse-Ergebnisse bei 4 spielenden Decks ·
    /// profile: Standard-Ansichts-Profile abwechselnd anwenden
    nonisolated static let mode = ProcessInfo.processInfo.environment["MIX741_BENCH"] ?? ""
    nonisolated static let requested = ["toggle", "state", "play", "browser", "profile"].contains(mode)

    static func snapshot(_ v: NSView, to path: String) {
        guard let layer = v.layer else { return }
        let w = Int(v.bounds.width), h = Int(v.bounds.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // nie das Interface einer laufenden Live-Session: schon beim Start nur ein eingebautes 2-Kanal-Gerät, stumm
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                                                forName: UserDefaults.argumentDomain)
        let store = LibraryStore(), mix = MixModel(), browser = BrowserState(), history = HistoryStore()
        browser.store = store
        browser.history = history
        // MIX741_BENCH_UI=live: Anordnung wie im Live-Set (2 Browser nebeneinander, Baum nur bei Browser groß, ohne Mixer)
        if let ui = ProcessInfo.processInfo.environment["MIX741_BENCH_UI"], ui.hasPrefix("live") {
            mix.prefs.ui.browserLayout = .sideBySide
            mix.prefs.ui.hideTreeWithDecks = ui == "live"
            mix.prefs.ui.showMixer = false
            mix.prefs.ui.browserHeight = 306
        }
        // wie im Fenster der App: Mindestgröße, Fenster fragt nur sie ab (Fenstergröße: .contentMinSize)
        let root = MinSize(width: 1280, height: 860) {
            ContentView()
                .environment(store).environment(mix).environment(browser)
                .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        }
        let host = WindowHostingView(rootView: root)
        host.sizingOptions = [.minSize]
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = rect
        func pump() { host.layoutSubtreeIfNeeded() }
        func log(_ s: String) { print("[bench] \(s)"); fflush(stdout) }
        Task { @MainActor in
            let core = mix.core
            if let dev = mix.outputDevices.first(where: { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") })
                ?? mix.outputDevices.first(where: { $0.channels < 8 }) {
                core.engine.deviceRate = nil
                core.engine.apply(.init(device: dev.id, firstChannel: [0, 0, 0, 0]))
            }
            core.engine.setMasterVolume(0)
            pump()
            if store.tracks.isEmpty, store.status == "Lade Collection …" { store.load() }
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(100)); pump() }
            // nur Dateien, die auf der Platte liegen: ein Platzhalter (Cloud, nur online) lädt im Selbsttest nie
            let fs = SystemCloudFileSystem()
            let c = Array(store.tracks.lazy.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists
                && fs.probe($0.path).state == .local }.prefix(8))
            guard c.count >= 4 else { log("zu wenige lokale Tracks"); exit(1) }
            // vier Ladevorgänge gleichzeitig mit niedriger Priorität (nice) brauchen länger als die 4 s des Wächters
            var p = mix.prefs.engine
            p.loadTimeout = 15   // nur im Kern, nicht gespeichert
            p.loadAbortTimeout = 15   // Datei-Dienst: nach 15 s ohne Daten abbrechen (sonst 60 s)
            core.setPrefs(p)
            for d in 0..<4 { mix.load(c[d], deck: d, force: true) }
            // nicht ladbar (Cloud-Datei hängt, Zeitlimit): nächster Kandidat statt endlos zu warten
            var next = 4
            while true {
                let s = core.snapshot()
                var waiting = false
                for d in 0..<4 where core.trackAudio(d) == nil {
                    if s.decks[d].loading { waiting = true } else if next < c.count { mix.load(c[next], deck: d, force: true); next += 1; waiting = true }
                }
                if !waiting { break }
                try? await Task.sleep(for: .milliseconds(100)); pump()
            }
            if let d = (0..<4).first(where: { core.trackAudio($0) == nil }) {
                log("Laden fehlgeschlagen: \(core.snapshot().decks[d].error ?? "kein Kandidat mehr")"); exit(1)
            }
            for d in 0..<4 { core.seek(d, seconds: 60) }
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
            if mode == "state" { await StateBench.run(mix: mix, host: host, log: log); exit(0) }
            if mode == "play" { await StateBench.play(mix: mix, log: log); exit(0) }
            if mode == "browser" { await StateBench.browser(mix: mix, store: store, browser: browser, host: host, log: log); exit(0) }
            if mode == "profile" {
                let profiles = LayoutProfile.defaults(from: mix.prefs.ui)
                // MIX741_BENCH_SPLIT=1: Wechsel Feld für Feld (Musik suchen -> Default Setup und zurück), Kosten je Feld
                if ProcessInfo.processInfo.environment["MIX741_BENCH_SPLIT"] == "1" {
                    let steps: [(String, (inout UIPrefs, LayoutProfile) -> Void)] = [
                        ("decks", { $0.deckCount = $1.deckCount }), ("mixer", { $0.showMixer = $1.showMixer }),
                        ("fx", { $0.showFXUnits = $1.showFXUnits; $0.fxUnitCount = $1.fxUnitCount }),
                        ("rows", { $0.deckRows = $1.deckRows; $0.showGridTools = $1.showGridTools }),
                        ("browser", { $0.browserLayout = $1.browserLayout; $0.browserHeight = $1.browserHeight; $0.hideTreeWithDecks = $1.hideTreeWithDecks }),
                        ("status", { $0.statusBar = $1.statusBar; $0.showMeters = $1.showMeters }),
                        ("cover+preview", { $0.showDeckCover = $1.showDeckCover; $0.showCoverPreview = $1.showCoverPreview; $0.previewMode = $1.previewMode; $0.waveformHeight = $1.waveformHeight
                            $0.deckCoverSize = $1.deckCoverSize; $0.overviewHeight = $1.overviewHeight }),
                    ]
                    var sums: [String: [Double]] = [:]
                    for r in 0..<6 {
                        let target = profiles[r % 2 == 0 ? 0 : 1]
                        LayoutProfiles.apply(profiles[r % 2 == 0 ? 1 : 0], mix: mix, browser: browser)
                        for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
                        for (name, f) in steps {
                            let t0 = CACurrentMediaTime()
                            f(&mix.prefs.ui, target)
                            host.layoutSubtreeIfNeeded()
                            CATransaction.flush()
                            if r >= 2 { sums["\(name) -> \(target.name)", default: []].append((CACurrentMediaTime() - t0) * 1000) }
                            for _ in 0..<3 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
                        }
                    }
                    for (k, v) in sums.sorted(by: { $0.key < $1.key }) { log(String(format: "%@: median %.1f ms", k, v.sorted()[v.count / 2])) }
                    exit(0)
                }
                let rounds = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_N"] ?? "") ?? 10
                var sums: [String: [Double]] = [:]
                for i in 0..<rounds * profiles.count {
                    let p = profiles[i % profiles.count]
                    let t0 = CACurrentMediaTime()
                    LayoutProfiles.apply(p, mix: mix, browser: browser)
                    host.layoutSubtreeIfNeeded()
                    let t1 = CACurrentMediaTime()
                    CATransaction.flush()
                    let t2 = CACurrentMediaTime()
                    if i >= profiles.count { sums[p.name, default: []].append((t2 - t0) * 1000) }   // erste Runde = Aufwärmen
                    log(String(format: "%@: layout %.1f ms, übergeben %.1f ms", p.name, (t1 - t0) * 1000, (t2 - t1) * 1000))
                    for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
                }
                for p in profiles {
                    let v = sums[p.name, default: []].sorted()
                    guard !v.isEmpty else { continue }
                    log(String(format: "→ %@: median %.1f ms, max %.1f ms (n=%d)", p.name, v[v.count / 2], v.last!, v.count))
                }
                exit(0)
            }
            let waves = { (v: NSView) -> [NSView] in
                var out: [NSView] = [], stack = [v]
                while let n = stack.popLast() { if n is WaveLayerNSView { out.append(n) }; stack += n.subviews }
                return out
            }
            let rounds = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_N"] ?? "") ?? 10
            var sums: [Bool: [Double]] = [true: [], false: []]
            // MIX741_BENCH_NATURAL=1 (mit MIX741_DEBUG=1): nur umschalten, Layout und Übergabe macht der Run-Loop wie
            // nach einem Tastendruck; ToggleProbe meldet [toggle] bis zum nächsten Display-Link-Takt
            if ProcessInfo.processInfo.environment["MIX741_BENCH_NATURAL"] != nil {
                for _ in 0..<rounds * 2 {
                    browser.maximized.toggle()
                    for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(100)); mix.pull() }
                }
                exit(0)
            }
            for i in 0..<rounds * 2 {
                let t0 = CACurrentMediaTime()
                browser.maximized.toggle()
                host.layoutSubtreeIfNeeded()
                let t1 = CACurrentMediaTime()
                CATransaction.flush()   // wie im Display-Zyklus: nur geänderte Ebenen zeichnen, übergeben
                let t2 = CACurrentMediaTime()
                let big = browser.maximized
                let sizes = waves(host).map { "\(Int($0.bounds.width))×\(Int($0.bounds.height))" }.joined(separator: " ")
                if i >= 2 { sums[big]?.append((t2 - t0) * 1000) }   // erste Runde = Aufwärmen
                if big, let hit = host.hitTest(NSPoint(x: 400, y: host.bounds.height - 200)),
                   hit is WaveLayerNSView || hit is LiveCanvasView { log("FEHLER: Klick im Browser landet in einem Deck (\(hit))") }
                log(String(format: "%@: layout %.1f ms, übergeben %.1f ms · wellen %@", big ? "browser groß" : "decks", (t1 - t0) * 1000, (t2 - t1) * 1000, sizes))
                for _ in 0..<4 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
                // MIX741_BENCH_PNG=<ordner>: beide Zustände als Bild (Layer-Baum offscreen gerendert) zum Vergleich
                if i < 2, let dir = ProcessInfo.processInfo.environment["MIX741_BENCH_PNG"] { snapshot(host, to: "\(dir)/\(big ? "big" : "decks").png") }
            }
            for big in [true, false] {
                let v = sums[big]!.sorted()
                guard !v.isEmpty else { continue }
                log(String(format: "→ %@: median %.1f ms, max %.1f ms (n=%d)", big ? "browser groß" : "decks", v[v.count / 2], v.last!, v.count))
            }
            exit(0)
        }
        app.run()
        exit(0)
    }
}

/// Fenster-Hosting-View der Messung: misst ihre Layout-Zeit wie BoundaryHostingView, meldet aber Größen normal
final class WindowHostingView<Content: View>: NSHostingView<Content> {
    override func layout() {
        TimedLayout.stack.append(0)
        let t0 = CACurrentMediaTime()
        super.layout()
        let dt = CACurrentMediaTime() - t0
        TimedLayout.times["window", default: 0] += dt - TimedLayout.stack.removeLast()
    }
}

/// MIX741_BENCH=state / play: Kosten einer Zustandsänderung bzw. Hauptthread-Last beim Abspielen, offscreen.
@MainActor
enum StateBench {
    private static let env = ProcessInfo.processInfo.environment

    /// Run-Loop-Beobachter ganz am Ende von beforeWaiting (nach SwiftUI-Update und CA-Commit):
    /// Zeit von der Änderung bis der Hauptthread wieder frei ist
    private static var pending: CFTimeInterval?
    private static var done: CFTimeInterval = 0
    private static var observer: CFRunLoopObserver?
    private static func installObserver() {
        guard observer == nil else { return }
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                if let t0 = pending { done = CACurrentMediaTime() - t0; pending = nil }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    /// nächster Display-Link-Takt nach der Änderung
    private final class Tick: NSObject {
        var cont: CheckedContinuation<CFTimeInterval, Never>?
        var link: CADisplayLink?
        @objc func fire() {
            link?.invalidate(); link = nil
            let c = cont; cont = nil
            c?.resume(returning: CACurrentMediaTime())
        }
    }

    private static func nextTick() async -> CFTimeInterval {
        let t = Tick()
        return await withCheckedContinuation { c in
            t.cont = c
            let l = NSScreen.main!.displayLink(target: t, selector: #selector(Tick.fire))
            t.link = l
            l.add(to: .main, forMode: .common)
        }
    }

    /// Hauptthread-CPU-Zeit (s)
    private static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let port = pthread_mach_thread_np(pthread_self())
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// MIX741_BENCH_SAMPLE=<datei>: `sample` des eigenen Prozesses während der Messung
    private static func startSample(seconds: Int) -> Process? {
        guard let path = env["MIX741_BENCH_SAMPLE"] else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "\(seconds)", "-mayDie", "-file", path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        return p
    }

    private static func stats(_ v: [Double]) -> String {
        let s = v.sorted()
        guard !s.isEmpty else { return "–" }
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "median %5.1f · p95 %5.1f · max %5.1f ms", s[s.count / 2], p95, s.last!)
    }

    static func run(mix: MixModel, host: NSView, log: (String) -> Void) async {
        installObserver()
        let n = Int(env["MIX741_BENCH_N"] ?? "") ?? 20
        let d = 0
        var cueSet = false, tempo = false, loopIdx = 0, jumpIdx = 0, cut = false
        // MIX741_BENCH_EDIT=1: Deck A im EDIT-Modus (Grid- und Schnitt-Zeile, Griffe in der Wellenform)
        if env["MIX741_BENCH_EDIT"] != nil { mix.setEditing(d, true); try? await Task.sleep(for: .milliseconds(300)) }
        let actions: [(String, () -> Void)] = [
            ("play", { mix.togglePlay(d) }),
            ("sync", { mix.toggleSync(d) }),
            ("loop", { mix.autoLoop(d) }),
            ("loop size", { loopIdx += 1; mix.core.setLoopSize(d, BeatSizes.loop[loopIdx % BeatSizes.loop.count]); mix.pull() }),
            ("jump size", { jumpIdx += 1; mix.setJumpSize(d, BeatSizes.jump[jumpIdx % BeatSizes.jump.count]) }),
            ("hotcue", { cueSet.toggle(); mix.hotcue(d, 7, delete: !cueSet) }),
            ("tempo", { tempo.toggle(); mix.setTempo(d, tempo ? 1.5 : 0) }),
            ("keylock", { mix.toggleKeylock(d) }),
            ("clock bpm", { tempo.toggle(); mix.setClockBPM(tempo ? 127 : 128) }),   // nur die Master-Clock-Leiste
            ("gain", { tempo.toggle(); mix.updateDeck(d) { $0.gainDb = tempo ? 1 : 0 } }),   // ohne Mixer unsichtbar: Grundkosten
            ("edit", { mix.toggleEdit(d) }),   // EDIT-Modus an/aus: Zeilen tauschen, Griffe
            ("cut", { cut.toggle(); if cut { mix.setTrimPoint(d, end: false, 55) } else { mix.clearTrim(d) } }),   // Schnitt-Anfang setzen/weg
        ].filter { a in env["MIX741_BENCH_ONLY"].map { $0.split(separator: ",").contains(Substring(a.0)) } ?? true }
        let sampler = startSample(seconds: max(5, actions.count * n * 2 * 60 / 1000))
        if sampler != nil { try? await Task.sleep(for: .milliseconds(500)) }
        // MIX741_BENCH_PNG=<ordner>: Ausgangszustand und ein Zustand mit allem an (Sync, Keylock, Loop 8, Sprung 16,
        // Hotcue 8, Tempo +1.5 %) als Bild – für den Vergleich vorher/nachher
        if let dir = env["MIX741_BENCH_PNG"] {
            func shot(_ name: String) async {
                try? await Task.sleep(for: .milliseconds(600))
                host.layoutSubtreeIfNeeded()
                ToggleBench.snapshot(host, to: "\(dir)/\(name).png")
            }
            await shot("state-0")
            mix.toggleSync(d); mix.toggleKeylock(d); mix.core.setLoopSize(d, 8); mix.autoLoop(d); mix.setJumpSize(d, 16)
            mix.hotcue(d, 7); mix.setTempo(d, 1.5)
            await shot("state-1")
            mix.toggleSync(d); mix.toggleKeylock(d); mix.autoLoop(d); mix.hotcue(d, 7, delete: true); mix.setTempo(d, 0)
            mix.core.setLoopSize(d, 4); mix.setJumpSize(d, 4)
            // EDIT-Modus mit Schnitt kurz vor der Position und eigenem Grid
            let wasEditing = mix.editing(d)
            if !wasEditing { mix.toggleEdit(d) }
            mix.setTrimPoint(d, end: false, 58); mix.shiftGrid(d, ms: 1)
            await shot("state-edit")
            mix.clearTrim(d); mix.shiftGrid(d, ms: -1)
            if !wasEditing { mix.toggleEdit(d) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        var all: [Double] = [], allSync: [Double] = []
        log("deck A, n=\(n) je aktion · natural = änderung bis hauptthread frei (nach swiftui + ca-commit) · tick = bis nächster display-link-takt · sync = layout + flush direkt")
        TimedLayout.times = [:]
        for (name, act) in actions {
            var natural: [Double] = [], tick: [Double] = [], sync: [Double] = [], command: [Double] = []
            for i in 0..<(n + 2) {
                // natürlich: wie nach Klick/Controller – Run-Loop macht Update und Commit
                let t0 = CACurrentMediaTime()
                pending = t0
                act()
                let ta = CACurrentMediaTime()
                let t1 = await nextTick()
                try? await Task.sleep(for: .milliseconds(30))
                if i >= 2 { natural.append(done * 1000); tick.append((t1 - t0) * 1000); command.append((ta - t0) * 1000) }
                // direkt: Layout erzwingen und übergeben
                let s0 = CACurrentMediaTime()
                act()
                host.layoutSubtreeIfNeeded()
                CATransaction.flush()
                let s1 = CACurrentMediaTime()
                pending = nil
                if i >= 2 { sync.append((s1 - s0) * 1000) }
                try? await Task.sleep(for: .milliseconds(30))
            }
            all += natural; allSync += sync
            if env["MIX741_BENCH_LAYOUT"] != nil {
                log("   befehl + pull (ohne ui): \(stats(command))")
                log("   layout je hosting-view (ms je änderung): " + TimedLayout.times.sorted { $0.key < $1.key }
                    .map { String(format: "%@ %.2f", $0.key, $0.value * 1000 / Double(2 * (n + 2))) }.joined(separator: " · "))
                TimedLayout.times = [:]
            }
            log("\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) natural \(stats(natural)) | tick \(stats(tick)) | sync \(stats(sync))")
        }
        log("→ alle      natural \(stats(all)) | sync \(stats(allSync)) · >16 ms: \(all.filter { $0 > 16 }.count)/\(all.count)")
        sampler?.waitUntilExit()
    }

    /// Decks spielen lassen (MIX741_BENCH_DECKS=2|4), Hauptthread-Last, Hänger und Wellenform-Takte messen
    static func play(mix: MixModel, log: (String) -> Void) async {
        let decks = Int(env["MIX741_BENCH_DECKS"] ?? "") ?? 2
        let secs = Double(env["MIX741_BENCH_SECS"] ?? "") ?? 10
        for d in 0..<decks { mix.togglePlay(d) }
        try? await Task.sleep(for: .seconds(2))
        var last = CACurrentMediaTime(), hitches: [Double] = []
        let h = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            if now - last > 0.016 { hitches.append((now - last) * 1000) }
            last = now
        }
        RunLoop.main.add(h, forMode: .common)
        let sampler = startSample(seconds: Int(secs))
        WaveLayerNSView.benchReset()
        let c0 = mainThreadCPU(), w0 = CACurrentMediaTime()
        try? await Task.sleep(for: .seconds(secs))
        let c1 = mainThreadCPU(), w1 = CACurrentMediaTime()
        h.invalidate()
        let wall = w1 - w0
        let w = WaveLayerNSView.bench
        log(String(format: "%d decks spielen %.0f s: hauptthread %.1f %% eines kerns · wellen-takte %.0f/s je deck, verschoben %.0f/s, step+commit %.2f ms/s · hänger >16 ms: %d %@",
                   decks, wall, (c1 - c0) / wall * 100, Double(w.steps) / wall / 4, Double(w.moves) / wall, w.seconds / wall * 1000,
                   hitches.count, hitches.map { String(format: "%.0f", $0) }.joined(separator: " ")))
        // Gleichmäßigkeit: Bewegung der Wellenform je Bild in Gerätepixeln (laufende Decks)
        let px = w.px.sorted()
        if !px.isEmpty {
            let med = px[px.count / 2], mean = px.reduce(0, +) / Double(px.count)
            let dev = px.map { abs($0 - mean) }.reduce(0, +) / Double(px.count)
            let q = { (f: Double) in px[min(px.count - 1, Int(Double(px.count) * f))] }
            log(String(format: "   wellenform je bild (%@): median %.1f px, mittlere abweichung %.2f px, p5–p95 %.0f–%.0f px, ohne bewegung %.1f %% (n=%d)",
                       env["MIX741_BENCH_RAW"] != nil ? "roh" : "geglättet", med, dev, q(0.05), q(0.95),
                       Double(px.filter { $0 == 0 }.count) / Double(px.count) * 100, px.count))
        }
        sampler?.waitUntilExit()
    }
}

/// MIX741_BENCH=browser: Browser-Aktionen bei 4 spielenden Decks (MIX741_BENCH_UI=live: 2 Browser nebeneinander).
/// Je Aktion „natural“ (Änderung bis Hauptthread frei) und alle Lücken des Hauptthreads > 16 ms im Abschnitt.
/// Abschnitte: model search typing role tag sort source scroll prep load analysis session idle (MIX741_BENCH_ONLY=a,b),
/// MIX741_BENCH_N Wiederholungen, MIX741_BENCH_ALL=1 alle Werte, MIX741_BENCH_PREVIEW=row|column|title|off, MIX741_BENCH_ROWS=2,
/// MIX741_BENCH_PROFILE=<abschnitt> Hauptthread-Profil (MainSampler), MIX741_BENCH_SAMPLE=<datei> `sample` des Prozesses.
extension StateBench {
    static func browser(mix: MixModel, store: LibraryStore, browser: BrowserState, host: NSView, log: (String) -> Void) async {
        installObserver()
        let n = Int(env["MIX741_BENCH_N"] ?? "") ?? 10
        let only = env["MIX741_BENCH_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        for d in 0..<4 { mix.togglePlay(d) }
        try? await Task.sleep(for: .seconds(1))
        var gaps: [Double] = []
        var last = CACurrentMediaTime()
        let h = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            if now - last > 0.016 { gaps.append((now - last) * 1000) }
            last = now
        }
        RunLoop.main.add(h, forMode: .common)
        func natural(_ act: () -> Void) async -> Double {
            done = 0
            pending = CACurrentMediaTime()
            act()
            _ = await nextTick()
            try? await Task.sleep(for: .milliseconds(40))
            return done * 1000
        }
        func report(_ name: String, _ v: [Double]) {
            let g = gaps.sorted()
            log("\(name.padding(toLength: 9, withPad: " ", startingAt: 0)) natural \(stats(v)) · lücken >16 ms: \(g.count)"
                + (g.isEmpty ? "" : String(format: ", max %.0f ms", g.last!)))
            if env["MIX741_BENCH_ALL"] != nil {
                log("   " + v.map { String(format: "%.0f", $0) }.joined(separator: " "))
                if !g.isEmpty { log("   lücken: " + gaps.map { String(format: "%.0f", $0) }.joined(separator: " ")) }
            }
            gaps = []
        }
        let profiler = env["MIX741_BENCH_PROFILE"].map { _ in MainSampler() }
        var profiling = false
        func phase(_ name: String) -> Bool {
            if profiling { profiler?.stop(log: log); profiling = false }
            gaps = []
            last = CACurrentMediaTime()   // Arbeit des vorigen Abschnitts nicht mitzählen
            let on = only?.contains(name) ?? true
            if on, env["MIX741_BENCH_PROFILE"] == name { profiler?.start(); profiling = true }
            return on
        }
        // MIX741_BENCH_PREVIEW=row|column|title|off: Browser-Vorschau
        if let m = env["MIX741_BENCH_PREVIEW"] {
            mix.prefs.ui.previewMode = ["row": .fullRow, "column": .column, "title": .behindTitle][m] ?? .off
            try? await Task.sleep(for: .seconds(1))
        }
        // MIX741_BENCH_ROWS=2: beide Bereiche zweizeilig mit Detailleiste
        if env["MIX741_BENCH_ROWS"] == "2" {
            for p in [browser.paneA, browser.paneB] { p.twoLine = true; p.detailBar = true }
            try? await Task.sleep(for: .seconds(1))
        }
        let sampler = startSample(seconds: Int(env["MIX741_BENCH_SECS"] ?? "") ?? 20)
        let a = browser.paneA
        log("4 decks spielen (stumm), browser \(mix.prefs.ui.browserLayout.rawValue), \(store.tracks.count) tracks, n=\(n)")

        if phase("model") {
            // nur die Liste (ohne Oberfläche): Filter / Sortierung je Aktion
            let seps = mix.prefs.ui.tagSeparators
            func cost(_ name: String, _ act: () -> Void) {
                var v: [Double] = []
                for _ in 0..<n {
                    act()
                    let t0 = CACurrentMediaTime()
                    _ = a.rows(from: store, history: nil, separators: seps)
                    v.append((CACurrentMediaTime() - t0) * 1000)
                }
                log("model \(name.padding(toLength: 7, withPad: " ", startingAt: 0)) \(stats(v))")
            }
            var i = 0
            cost("search") { i += 1; a.search = i % 2 == 0 ? "tech" : "techn" }
            a.search = ""
            cost("role") { a.roles = a.roles.isEmpty ? [.basis] : [] }
            a.roles = []
            cost("sort") { i += 1; a.sortOrder = [i % 2 == 0 ? KeyPathComparator(\Track.title) : KeyPathComparator(\Track.artist)] }
            a.sortOrder = [KeyPathComparator(\Track.artist)]
            cost("prep") { store.preparation = store.preparation.isEmpty ? [store.tracks[0].key] : [] }
            store.preparation = []
            cost("match") { a.matching.toggle() }
            a.matching = false
            cost("harmony") { i += 1; a.sortOrder = [i % 2 == 0 ? KeyPathComparator(\Track.harmonySort) : KeyPathComparator(\Track.artist)] }
            a.sortOrder = [KeyPathComparator(\Track.artist)]
            gaps = []
        }
        if phase("search") {
            var v: [Double] = []
            let word = Array("techno")
            for _ in 0..<max(1, n / 4) {
                for i in 1...word.count { v.append(await natural { a.search = String(word[0..<i]) }) }
                for i in (0..<word.count).reversed() { v.append(await natural { a.search = String(word[0..<i]) }) }
            }
            report("search", v)
        }
        if phase("typing") {
            // „techno“ ins Suchfeld von Bereich A tippen, 10 Zeichen je Sekunde: Neuaufbauten der Liste und Lücken
            var fields: [NSTextField] = [], stack = [host]
            while let v = stack.popLast() { if let f = v as? NSTextField, f.placeholderString == "SUCHEN" { fields.append(f) }; stack += v.subviews }
            if let f = fields.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
               f.window?.makeFirstResponder(f) == true, let editor = f.currentEditor() {
                for _ in 0..<max(1, n / 4) {
                    let g0 = a.tableGeneration
                    let t0 = CACurrentMediaTime()
                    for c in "techno" {
                        editor.insertText(String(c))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    while a.search != "techno", CACurrentMediaTime() - t0 < 5 { try? await Task.sleep(for: .milliseconds(10)) }
                    _ = await natural {}
                    log(String(format: "typing    6 tasten: %d neuaufbauten, fertig nach %.0f ms", a.tableGeneration - g0, (CACurrentMediaTime() - t0) * 1000))
                    editor.selectAll(nil)
                    editor.deleteBackward(nil)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                report("typing", [])
            } else {
                log("typing: kein Suchfeld")
            }
        }
        if phase("role") {
            var v: [Double] = []
            for _ in 0..<n { v.append(await natural { if a.roles.isEmpty { a.roles = [.basis] } else { a.roles = [] } }) }
            a.roles = []
            report("role", v)
        }
        if phase("tag") {
            let seps = mix.prefs.ui.tagSeparators
            let counts = Dictionary(store.tracks.flatMap { BrowserPaneModel.tags(of: $0, separators: seps) }.map { ($0, 1) }, uniquingKeysWith: +)
            if let top = counts.max(by: { $0.value < $1.value })?.key {
                var v: [Double] = []
                for _ in 0..<n { v.append(await natural { a.toggleTag(top, exclude: false) }) }
                a.clearTags()
                report("tag", v)
            }
        }
        if phase("sort") {
            let orders: [KeyPathComparator<Track>] = [KeyPathComparator(\Track.title), KeyPathComparator(\Track.bpm),
                                                      KeyPathComparator(\Track.openKey), KeyPathComparator(\Track.artist)]
            var v: [Double] = []
            for i in 0..<n { v.append(await natural { a.sortOrder = [orders[i % orders.count]] }) }
            a.sortOrder = [KeyPathComparator(\Track.artist)]
            report("sort", v)
        }
        if phase("master") {
            // Master-Wechsel zwischen den spielenden Decks: ohne Key-Farben (Vergleich), mit (nur Key-/Match-Zellen der
            // sichtbaren Zeilen), mit Matching an (Liste neu im Hintergrund), nochmal mit Farben
            for (name, colors, match) in [("master-0", false, false), ("master", true, false), ("master+m", true, true), ("master", true, false)] {
                mix.prefs.ui.harmonyColors = colors
                a.matching = match
                try? await Task.sleep(for: .milliseconds(500))
                gaps = []
                var v: [Double] = []
                for i in 0..<n { v.append(await natural { mix.toggleMaster(i % 4) }) }
                log("\(name): bezug \(mix.harmonyKey.map(Track.openKey(code:)) ?? "-") \(mix.harmonyBPM), zeilen \(a.shown.count)")
                report(name, v)
            }
            mix.prefs.ui.harmonyColors = true
            a.matching = false
        }
        if phase("match") {
            var v: [Double] = []
            for _ in 0..<n { v.append(await natural { a.matching.toggle() }) }
            a.matching = false
            report("match", v)
            v = []
            for i in 0..<n { v.append(await natural { a.sortOrder = [i % 2 == 0 ? KeyPathComparator(\Track.harmonySort) : KeyPathComparator(\Track.artist)] }) }
            a.sortOrder = [KeyPathComparator(\Track.artist)]
            report("harmony", v)
        }
        // Track-Tabelle von Bereich A (links)
        func tableA() -> NSTableView? {
            var tables: [NSTableView] = [], stack = [host]
            while let v = stack.popLast() { if let t = v as? NSTableView, t.tableColumns.count > 1 { tables.append(t) }; stack += v.subviews }
            return tables.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        if phase("source") {
            func lists(_ n: PlaylistNode) -> [PlaylistNode] { (n.kind == .playlist ? [n] : []) + n.children.flatMap(lists) }
            if let big = lists(store.root).max(by: { $0.trackKeys.count < $1.trackKeys.count }) {
                // Fokus in der Tabelle (Pfeiltasten): bleibt er nach dem Listenwechsel in der Tabelle?
                let old = tableA()
                if let old { old.window?.makeFirstResponder(old) }
                var v: [Double] = []
                for i in 0..<n { v.append(await natural { a.source = i % 2 == 0 ? .node(big) : .collection }) }
                a.source = .collection
                try? await Task.sleep(for: .milliseconds(300))
                let now = tableA()
                log("source    fokus: " + (now != nil && host.window?.firstResponder === now ? (now === old ? "tabelle" : "neue tabelle") : "FEHLER: verloren"))
                report("source", v)
            }
        }
        if phase("scroll") {
            // Liste von Bereich A scrollen wie mit Mausrad / Trackpad: je Schritt 3 Zeilen
            if let tv = tableA(), let clip = tv.enclosingScrollView?.contentView {
                let step = tv.rect(ofRow: 0).height * 3
                var v: [Double] = []
                for i in 0..<(n * 4) {
                    v.append(await natural {
                        clip.scroll(to: NSPoint(x: 0, y: CGFloat(i + 1) * step))
                        tv.enclosingScrollView?.reflectScrolledClipView(clip)
                    })
                }
                clip.scroll(to: .zero)
                report("scroll", v)
            }
        }
        if phase("prep") {
            let keys = store.tracks.prefix(n).map(\.key)
            var v: [Double] = []
            for k in keys { v.append(await natural { store.preparation.append(k) }) }
            store.preparation = []
            report("prep", v)
        }
        if phase("load") {
            let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.fileExists && $0.duration > 120 }.dropFirst(4).prefix(2)
            if c.count == 2 {
                var v: [Double] = []
                for i in 0..<max(2, n / 2) {
                    let t = c[c.startIndex + i % 2]
                    v.append(await natural { mix.load(t, deck: 3, force: true) })
                    for _ in 0..<200 where mix.deck(3).loading { try? await Task.sleep(for: .milliseconds(50)) }
                    mix.togglePlay(3)
                    try? await Task.sleep(for: .milliseconds(500))
                }
                report("load", v)
            }
        }
        if phase("analysis") {
            // Ergebnisse wie vom Analyse-Stapel: 2 je Sekunde, 10 s (Speicher nur im Arbeitsspeicher), Decks spielen ->
            // gesammelt; natural = Übernahme am Ende des Stapels
            let pick = store.tracks.filter { $0.bpm > 0 }.prefix(20)
            for (i, t) in pick.enumerated() {
                Analyses.shared.store.put(TrackAnalysis(bpm: t.bpm + 0.01, perceivedDb: -1 - Double(i % 3)), for: t.key, replace: false)
                try? await Task.sleep(for: .milliseconds(500))
            }
            let v = await natural { Analyses.shared.flush() }
            report("analysis", [v])
        }
        if phase("session") {
            var v: [Double] = []
            for _ in 0..<n {
                let t0 = CACurrentMediaTime()
                _ = try? JSONEncoder().encode(Session(mix: mix, browser: browser))
                v.append((CACurrentMediaTime() - t0) * 1000)
            }
            report("session", v)
        }
        if phase("idle") {
            try? await Task.sleep(for: .seconds(Double(env["MIX741_BENCH_SECS"] ?? "") ?? 10))
            report("idle", [])
        }
        if profiling { profiler?.stop(log: log) }
        h.invalidate()
        sampler?.waitUntilExit()
    }
}

/// Messung (MIX741_BENCH_PROFILE=<abschnitt>): Hauptthread alle 1 ms anhalten, Rücksprungadressen über die
/// Frame-Pointer sammeln, am Ende nach Funktion zählen (inklusiv / selbst). Nur für die Messungen, nie in der App.
final class MainSampler: @unchecked Sendable {
    private let port = pthread_mach_thread_np(pthread_self())
    private let lo: UInt, hi: UInt
    private let lock = NSLock()
    private var stacks: [[UInt]] = []
    private var running = false

    /// auf dem Hauptthread anlegen
    init() {
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        hi = top
        lo = top - UInt(pthread_get_stacksize_np(pthread_self()))
    }

    func start() {
        lock.withLock { stacks = []; running = true }
        let t = Thread { [self] in
            while lock.withLock({ running }) {
                if let s = sample() { lock.withLock { stacks.append(s) } }
                usleep(1000)
            }
        }
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func sample() -> [UInt]? {
        #if arch(arm64)
        guard thread_suspend(port) == KERN_SUCCESS else { return nil }
        defer { thread_resume(port) }
        var st = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let r = withUnsafeMutablePointer(to: &st) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(port, ARM_THREAD_STATE64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var out = [UInt(st.__pc) & mask, UInt(st.__lr) & mask]
        var fp = UInt(st.__fp)
        for _ in 0..<160 {
            guard fp >= lo, fp + 16 <= hi, fp % 8 == 0, let p = UnsafePointer<UInt>(bitPattern: fp) else { break }
            let next = p[0], ret = p[1] & mask
            if ret != 0 { out.append(ret) }
            guard next > fp else { break }
            fp = next
        }
        return out
        #else
        return nil   // Profiler nur auf Apple Silicon (Frame-Pointer-Kette über den ARM-Thread-Zustand)
        #endif
    }

    /// stoppen und die häufigsten Funktionen melden
    func stop(top: Int = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_PROFILE_TOP"] ?? "") ?? 45, log: (String) -> Void) {
        let all: [[UInt]] = lock.withLock { running = false; return stacks }
        guard !all.isEmpty else { return }
        var names: [UInt: String] = [:]
        func name(_ a: UInt) -> String {
            if let n = names[a] { return n }
            var info = Dl_info()
            var n = "?"
            if dladdr(UnsafeRawPointer(bitPattern: a), &info) != 0 {
                let img = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
                n = (info.dli_sname.map { String(cString: $0) } ?? String(format: "0x%lx", a)) + " [\(img)]"
            }
            names[a] = n
            return n
        }
        var incl: [String: Int] = [:], selfc: [String: Int] = [:]
        for s in all {
            var seen = Set<String>()
            for (i, a) in s.enumerated() {
                let n = name(a)
                if i == 0 { selfc[n, default: 0] += 1 }
                if seen.insert(n).inserted { incl[n, default: 0] += 1 }
            }
        }
        let total = Double(all.count)
        log(String(format: "profil: %d proben (1 ms)", all.count))
        for (n, c) in incl.sorted(by: { $0.value > $1.value }).prefix(top) {
            log(String(format: "  %5.1f %% incl  %5.1f %% self  %@", Double(c) / total * 100, Double(selfc[n] ?? 0) / total * 100, n))
        }
        log("  -- selbst:")
        for (n, c) in selfc.sorted(by: { $0.value > $1.value }).prefix(15) {
            log(String(format: "  %5.1f %% self  %@", Double(c) / total * 100, n))
        }
    }
}
