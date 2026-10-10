import AppKit
import QuartzCore
import SwiftUI

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
    nonisolated static var requested: Bool { ProcessInfo.processInfo.environment["MIX741_BENCH"] == "toggle" }

    private static func snapshot(_ v: NSView, to path: String) {
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
