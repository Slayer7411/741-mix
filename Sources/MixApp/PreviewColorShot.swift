import AppKit
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SHOT=previewcolors:<ordner>): Vorschau-Bilder echter Tracks vorher (wie Wellenform) und
/// nachher (Spektrum) als PNG – kein Fenster, kein Audio, Collection nur gelesen, Übersichten nur im Speicher.
/// Auswahl: MIX741_SHOT_TRACKS="teil1|teil2|…" (Dateiname enthält), sonst aus den neuesten 80 Tracks mit Grid je
/// 2 mit dem meisten Bass-, Mitten- und Höhenanteil.
@MainActor
enum PreviewColorShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let shot = ProcessInfo.processInfo.environment["MIX741_SHOT"], shot.hasPrefix("previewcolors:") else { return }
        let dir = URL(fileURLWithPath: String(shot.dropFirst("previewcolors:".count)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        func log(_ s: String) { print("[colors] \(s)"); fflush(stdout) }
        let prefs = AppPrefs.load()
        let store = LibraryStore()
        store.load()
        Task { @MainActor in
            while store.tracks.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            let env = ProcessInfo.processInfo.environment
            var picks: [(Track, TrackOverview)] = []
            let pool = store.tracks.filter { $0.fileExists && !$0.loose && $0.bpm > 0 && $0.gridAnchorMs != nil }
            if let names = env["MIX741_SHOT_TRACKS"] {
                for n in names.split(separator: "|") {
                    guard let t = pool.first(where: { $0.path.localizedCaseInsensitiveContains(n) }) else { log("nicht gefunden: \(n)"); continue }
                    if let o = await analyze(t) { picks.append((t, o)) }
                }
            } else {
                var cand: [(Track, TrackOverview, (Float, Float, Float))] = []
                for t in pool.sorted(by: { $0.importSort > $1.importSort }).prefix(80) {
                    guard let o = await analyze(t) else { continue }
                    var l: Float = 0, m: Float = 0, h: Float = 0
                    for i in 0..<o.count { l += o.low(i); m += o.mid(i); h += o.high(i) }
                    cand.append((t, o, (l, m, h)))
                }
                var used = Set<String>()
                for band in 0..<3 {
                    let sorted = cand.sorted { a, b in
                        [a.2.0, a.2.1, a.2.2][band] > [b.2.0, b.2.1, b.2.2][band]
                    }
                    for c in sorted where !used.contains(c.0.key) && picks.count < (band + 1) * 2 {
                        used.insert(c.0.key); picks.append((c.0, c.1))
                    }
                }
            }
            let w = PreviewRenderer.width, h = PreviewRenderer.height, gap = 6
            let rows = picks.count * 2
            guard rows > 0, let ctx = CGContext(data: nil, width: w, height: rows * (h + gap), bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { log("nichts"); exit(1) }
            ctx.setFillColor(CGColor(srgbRed: 10 / 255, green: 9 / 255, blue: 8 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: rows * (h + gap)))
            for (k, (t, o)) in picks.enumerated() {
                var l: Float = 0, m: Float = 0, hi: Float = 0
                for i in 0..<o.count { l += o.low(i); m += o.mid(i); hi += o.high(i) }
                let n = Float(max(1, o.count))
                log(String(format: "%d: %@ – %@ · bass %.2f mitten %.2f höhen %.2f · drops %@", k + 1, t.artist, t.title, l / n, m / n, hi / n,
                           OverviewPaint.drops(o).map { String(format: "%.0f%%", $0 * 100) }.joined(separator: " ")))
                for (j, colors) in [PreviewColors.waveform, .spectrum].enumerated() {
                    var ui = prefs.ui
                    ui.previewColors = colors
                    let spec = PreviewSpec(t, ui: ui, controller: prefs.controller, overview: o)
                    guard let img = PreviewRenderer.render(spec, overview: o) else { continue }
                    let y = rows * (h + gap) - (k * 2 + j + 1) * (h + gap)
                    ctx.draw(img, in: CGRect(x: 0, y: y, width: w, height: h))
                    write(img, dir.appendingPathComponent(String(format: "%02d-%@.png", k + 1, j == 0 ? "before" : "after")))
                }
            }
            // Zeichenzeit je Bild (Durchschnitt über alle Tracks, je 20×)
            for colors in [PreviewColors.waveform, .spectrum] {
                var ui = prefs.ui
                ui.previewColors = colors
                let specs = picks.map { (PreviewSpec($0.0, ui: ui, controller: prefs.controller, overview: $0.1), $0.1) }
                let t0 = Date()
                for _ in 0..<20 { for (s, o) in specs { _ = PreviewRenderer.render(s, overview: o) } }
                log(String(format: "zeichnen %@: %.3f ms je bild", colors.rawValue, Date().timeIntervalSince(t0) * 1000 / Double(20 * max(1, specs.count))))
            }
            if let all = ctx.makeImage() { write(all, dir.appendingPathComponent("preview-colors.png")) }
            log("bilder in \(dir.path) (je track: vorher = wie wellenform, nachher = spektrum)")
            exit(0)
        }
        NSApplication.shared.run()
    }

    private static func analyze(_ t: Track) async -> TrackOverview? {
        await Task.detached(priority: .userInitiated) { try? OverviewAnalyzer.analyze(url: URL(fileURLWithPath: t.path)) }.value
    }

    private static func write(_ img: CGImage, _ url: URL) {
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
