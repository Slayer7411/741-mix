import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SELFTEST=1 MIX741_SHOT=cover:<ordner>): Cover offscreen prüfen, ohne Fenster auf dem Bildschirm,
/// ohne Audio. Stichprobe (MIX741_COVER_SAMPLE, Standard 200 Tracks): eingebettet / Ordner / keins; dann Deck A–D mit
/// echten Tracks (deck-A.png …) und der Browser mit Cover-Spalte und Vorschau (browser.png).
/// MIX741_COVER_BENCH=1: Liste offscreen durchscrollen, Layout je Schritt messen (MIX741_COVER_COLUMN=0: ohne Spalte).
/// Cache-Ordner für Messungen: MIX741_ARTWORK_DIR.
@MainActor
enum CoverShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("cover:") else { return }
        let dir = URL(fileURLWithPath: String(spec.dropFirst(6)))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        let withColumn = env["MIX741_COVER_COLUMN"] != "0"
        // Spalten der Schuss-Tabelle (eigener Name, nur flüchtig): Cover sichtbar
        var cols = TableColumnCustomization<Track>()
        cols[visibility: "cover"] = withColumn ? .visible : .hidden
        // nie das Interface einer laufenden Live-Session: Routing nur für diesen Prozess auf ein eingebautes Gerät, stumm
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        UserDefaults.standard.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0,
                                                 "columns.COVER-SHOT": (try? JSONEncoder().encode(cols)) ?? Data()],
                                                forName: UserDefaults.argumentDomain)
        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        let mix = MixModel()
        mix.engine.stop()   // kein Ton, Gerät sofort frei
        mix.prefs.ui.hideTreeWithDecks = false
        mix.prefs.ui.showDeckCover = true
        mix.prefs.ui.showCoverPreview = true
        store.load()
        Task { @MainActor in
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            log("collection \(store.tracks.count) tracks · cache \(ArtworkCache.shared.directory.path)")

            // Stichprobe: feste Auswahl (gleiche Tracks bei jedem Lauf)
            let n = Int(env["MIX741_COVER_SAMPLE"] ?? "") ?? 200
            var rng = SplitMix(seed: 741)
            let pool = store.tracks.filter(\.fileExists)
            let sample = Array(pool.shuffled(using: &rng).prefix(n))
            let t0 = CACurrentMediaTime()
            let found = await withTaskGroup(of: (Track, ArtworkCache.Source?).self) { g in
                var out: [(Track, ArtworkCache.Source?)] = []
                var it = sample.makeIterator()
                for _ in 0..<4 { if let t = it.next() { g.addTask { (t, await ArtworkCache.shared.find(t.path)?.1) } } }
                while let r = await g.next() {
                    out.append(r)
                    if let t = it.next() { g.addTask { (t, await ArtworkCache.shared.find(t.path)?.1) } }
                }
                return out
            }
            let dt = CACurrentMediaTime() - t0
            let order = Dictionary(sample.enumerated().map { ($1.key, $0) }, uniquingKeysWith: min)
            let ordered = found.sorted { order[$0.0.key, default: 0] < order[$1.0.key, default: 0] }
            let emb = ordered.filter { $0.1 == .embedded }, fold = ordered.filter { $0.1 == .folder }
            log(String(format: "stichprobe %d: eingebettet %d, ordner %d, keins %d · %.1f ms je track",
                       found.count, emb.count, fold.count, found.count - emb.count - fold.count, dt * 1000 / Double(max(1, found.count))))
            for ext in Set(found.map { ($0.0.path as NSString).pathExtension.lowercased() }).sorted() {
                let f = found.filter { ($0.0.path as NSString).pathExtension.lowercased() == ext }
                log("  .\(ext): \(f.count) · eingebettet \(f.filter { $0.1 == .embedded }.count) · ordner \(f.filter { $0.1 == .folder }.count)")
            }

            if env["MIX741_COVER_VERBOSE"] == "1" { for (t, src) in ordered where src == nil { log("  ohne: \(t.path)") } }
            // Decks: zwei eingebettet, eins Ordner (falls vorhanden), eins ohne Cover
            let none = ordered.first { $0.1 == nil }?.0
            let picks = Array(emb.prefix(fold.isEmpty ? 3 : 2).map(\.0)) + fold.prefix(1).map(\.0) + [none].compactMap { $0 }
            for (d, t) in picks.prefix(4).enumerated() {
                mix.updateDeck(d) { $0.track = t; $0.duration = t.duration; $0.grid = BeatGrid(track: t) }
                _ = await ArtworkCache.shared.image(t.path, .large)
            }
            for d in 0..<min(4, picks.count) {
                let url = dir.appendingPathComponent("deck-\(deckLetters[d]).png")
                render(DeckView(d: d), mix: mix, store: store, history: history, browser: browser,
                       size: CGSize(width: 600, height: 260), to: url)
                log("PNG \(url.path) · \(picks[d].artist) – \(picks[d].title)")
            }

            // Browser: echte Liste, Auswahl = ein Track mit eingebettetem Cover aus der Stichprobe, dorthin gescrollt
            let pane = BrowserPaneModel(name: "COVER-SHOT")
            let rows = pane.rows(from: store, history: history, separators: " ")
            let pick = emb.dropFirst(4).first?.0 ?? emb.first?.0
            if let pick { pane.selection = [pick.key] }
            let size = CGSize(width: 1400, height: 720)
            let host = NSHostingView(rootView: root(BrowserPane(model: pane), mix: mix, store: store, history: history, browser: browser))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(200))
            if let pick, let i = rows.firstIndex(where: { $0.key == pick.key }), let tv = table(in: host) {
                tv.scrollRowToVisible(min(rows.count - 1, i + 12))
                tv.scrollRowToVisible(max(0, i - 12))
            }
            for _ in 0..<40 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(50)) }
            let url = dir.appendingPathComponent(withColumn ? "browser.png" : "browser-nocolumn.png")
            snapshot(host, to: url)
            log("PNG \(url.path) · \(rows.count) zeilen")
            // Kontrolle: sichtbare Zeilen geladen? (bild / kein cover / unbekannt = Zelle hat nicht geladen)
            let first = pick.flatMap { p in rows.firstIndex { $0.key == p.key } } ?? 0
            let top = rows[max(0, first - 13)..<min(rows.count, first + 13)].map { ArtworkCache.shared.cached($0.path, .small) }
            log("oberste \(top.count) zeilen: bild \(top.filter { $0 != nil && $0! != nil }.count), kein cover \(top.filter { $0 != nil && $0! == nil }.count), nicht geladen \(top.filter { $0 == nil }.count)")

            if env["MIX741_COVER_BENCH"] == "1" { await bench(host, rows: rows.count, column: withColumn) }
            exit(0)
        }
        NSApplication.shared.run()
    }

    /// Liste durchscrollen (20 Zeilen je Schritt, wie ein schneller Wisch), Layout + Übergabe je Schritt messen;
    /// dazwischen 8 ms Run-Loop, damit fertig geladene Cover ankommen. Größte Lücke = längste Blockade des Hauptthreads.
    private static func bench(_ host: NSView, rows: Int, column: Bool) async {
        guard let tv = table(in: host), let clip = tv.enclosingScrollView?.contentView else { log("keine tabelle"); return }
        let step = 20, steps = min(600, rows / step)
        var times: [Double] = [], gaps: [Double] = []
        var last = CACurrentMediaTime()
        for i in 0..<steps {
            let t0 = CACurrentMediaTime()
            gaps.append(t0 - last)
            clip.scroll(to: NSPoint(x: 0, y: tv.rect(ofRow: i * step).minY))
            tv.enclosingScrollView?.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let t1 = CACurrentMediaTime()
            times.append((t1 - t0) * 1000)
            try? await Task.sleep(for: .milliseconds(8))
            last = CACurrentMediaTime() - 0.008
        }
        times.sort()
        let p = { (q: Double) in times[min(times.count - 1, Int(Double(times.count) * q))] }
        log(String(format: "scroll %@: %d schritte à %d zeilen · layout median %.2f ms, p95 %.2f ms, max %.2f ms",
                   column ? "mit cover-spalte" : "ohne cover-spalte", steps, step, p(0.5), p(0.95), times.last ?? 0))
    }

    /// Track-Liste im Host (SwiftUI-Table = NSTableView mit mehreren Spalten; der Baum hat eine)
    private static func table(in host: NSView) -> NSTableView? {
        var stack: [NSView] = [host]
        while let v = stack.popLast() {
            if let t = v as? NSTableView, t.tableColumns.count > 1 { return t }
            stack += v.subviews
        }
        return nil
    }

    private static func root(_ v: some View, mix: MixModel, store: LibraryStore, history: HistoryStore, browser: BrowserState) -> some View {
        v.environment(mix).environment(store).environment(history).environment(browser)
            .environment(WaveformCache()).environment(ControllerStatus())
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
    }

    private static func render(_ v: some View, mix: MixModel, store: LibraryStore, history: HistoryStore, browser: BrowserState,
                               size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: root(v.frame(width: size.width, height: size.height), mix: mix, store: store, history: history, browser: browser))
        host.frame = CGRect(origin: .zero, size: size)
        // Fenster nur als Zeichenfläche, wird nie angezeigt
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        snapshot(host, to: url)
    }

    private static func snapshot(_ host: NSView, to url: URL) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func log(_ s: String) {
        print("[cover] \(s)")
        fflush(stdout)
    }

    /// kleiner fester Zufallsgenerator (gleiche Stichprobe bei jedem Lauf)
    private struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}
