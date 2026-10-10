import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

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
    /// toggle: Browser groß/klein · state: Zustandsänderungen an Deck A · play: Hauptthread-Last bei laufenden Decks
    nonisolated static var mode: String { ProcessInfo.processInfo.environment["MIX741_BENCH"] ?? "" }
    nonisolated static var requested: Bool { ["toggle", "state", "play"].contains(mode) }

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
        let root = ContentView()
            .environment(store).environment(mix).environment(browser)
            .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let host = NSHostingView(rootView: root)
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
            let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }
            guard c.count >= 4 else { log("zu wenige Tracks"); exit(1) }
            for d in 0..<4 { mix.load(c[d], deck: d) }
            while (0..<4).contains(where: { core.trackAudio($0) == nil }) { try? await Task.sleep(for: .milliseconds(100)); pump() }
            for d in 0..<4 { core.seek(d, seconds: 60) }
            for _ in 0..<30 { try? await Task.sleep(for: .milliseconds(100)); mix.pull(); pump() }
            if mode == "state" { await StateBench.run(mix: mix, host: host, log: log); exit(0) }
            if mode == "play" { await StateBench.play(mix: mix, log: log); exit(0) }
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
        var cueSet = false, tempo = false, loopIdx = 0, jumpIdx = 0
        let actions: [(String, () -> Void)] = [
            ("play", { mix.togglePlay(d) }),
            ("sync", { mix.toggleSync(d) }),
            ("loop", { mix.autoLoop(d) }),
            ("loop size", { loopIdx += 1; mix.core.setLoopSize(d, BeatSizes.loop[loopIdx % BeatSizes.loop.count]); mix.pull() }),
            ("jump size", { jumpIdx += 1; mix.setJumpSize(d, BeatSizes.jump[jumpIdx % BeatSizes.jump.count]) }),
            ("hotcue", { cueSet.toggle(); mix.hotcue(d, 7, delete: !cueSet) }),
            ("tempo", { tempo.toggle(); mix.setTempo(d, tempo ? 1.5 : 0) }),
            ("keylock", { mix.toggleKeylock(d) }),
            ("gain", { tempo.toggle(); mix.updateDeck(d) { $0.gainDb = tempo ? 1 : 0 } }),   // ohne Mixer unsichtbar: Grundkosten
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
            try? await Task.sleep(for: .milliseconds(300))
        }
        var all: [Double] = [], allSync: [Double] = []
        log("deck A, n=\(n) je aktion · natural = änderung bis hauptthread frei (nach swiftui + ca-commit) · tick = bis nächster display-link-takt · sync = layout + flush direkt")
        for (name, act) in actions {
            var natural: [Double] = [], tick: [Double] = [], sync: [Double] = []
            for i in 0..<(n + 2) {
                // natürlich: wie nach Klick/Controller – Run-Loop macht Update und Commit
                let t0 = CACurrentMediaTime()
                pending = t0
                act()
                let t1 = await nextTick()
                try? await Task.sleep(for: .milliseconds(30))
                if i >= 2 { natural.append(done * 1000); tick.append((t1 - t0) * 1000) }
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
        sampler?.waitUntilExit()
    }
}
