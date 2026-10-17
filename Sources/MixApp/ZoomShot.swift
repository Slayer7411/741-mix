import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SELFTEST=1 MIX741_SHOT=zoom:<ordner>): ganze Oberfläche offscreen je Zoom-Stufe
/// (MIX741_SHOT_ZOOM=1,1.5), Fenster 1600 × 1000 × Zoom, 4 Decks geladen. Je Stufe ein PNG und Messung:
/// Wechsel, Zeit je Aktualisierung, Ebenen unter Gerätepixeln, Lage der AppKit-Ansichten gegenüber der ersten Stufe.
/// Collection nur gelesen, Audio stumm auf einem eingebauten Gerät, Spaltenbreiten danach wie vorher.
@MainActor
enum ZoomShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("zoom:") else { return }
        let dir = URL(fileURLWithPath: String(spec.dropFirst(5)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        SelfTest.enabled = false
        let zooms = (ProcessInfo.processInfo.environment["MIX741_SHOT_ZOOM"] ?? "1,1.5").split(separator: ",").compactMap { Double($0) }

        // Audio-Setup sichern (MixModel schreibt es beim Start zurück), nur eingebaute Lautsprecher, stumm
        let d = E2E.defaults
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        // Spaltenbreiten der Tabellen (columns.*) ändern sich mit dem Zoom: am Ende wieder herstellen
        let columns = d.dictionaryRepresentation().filter { $0.key.hasPrefix("columns.") }
        let finish = { () -> Never in
            for k in d.dictionaryRepresentation().keys where k.hasPrefix("columns.") && columns[k] == nil { d.removeObject(forKey: k) }
            for (k, v) in columns { d.set(v, forKey: k) }
            exit(0)
        }

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        store.load()
        spin(120, until: { !store.tracks.isEmpty })
        let c = store.tracks.filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.fileExists }
        guard c.count >= 4 else { log("zu wenige Tracks"); exit(1) }
        for i in 0..<4 { mix.load(c[i], deck: i) }
        spin(60, until: { (0..<4).allSatisfy { mix.core.trackAudio($0) != nil } })
        for i in 0..<4 { mix.core.seek(i, seconds: 60) }
        mix.pull()

        ZoomControl.apply(zooms.first ?? 1)
        let root = ContentView()
            .environment(store).environment(mix).environment(browser)
            .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let base = NSSize(width: 1600, height: 1000)
        let first = zooms.first ?? 1
        let host = NSHostingView(rootView: root)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: base.width * first, height: base.height * first)),
                           styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        let px = win.backingScaleFactor
        let pump = { mix.pull(); host.layoutSubtreeIfNeeded(); CATransaction.flush() }
        spin(3, step: pump)
        log("Fenster offscreen, \(Int(px))x Pixel")

        var reference: [ObjectIdentifier: NSRect] = [:]
        for (n, z) in zooms.enumerated() {
            let tag = "zoom\(Int((z * 100).rounded()))"
            let t0 = CACurrentMediaTime()
            ZoomControl.apply(z)
            win.setContentSize(NSSize(width: base.width * z, height: base.height * z))
            host.layoutSubtreeIfNeeded()
            let t1 = CACurrentMediaTime()
            CATransaction.flush()
            let t2 = CACurrentMediaTime()
            spin(3, step: pump)   // Kacheln im Hintergrund, Zeilen-Vorschauen
            log(String(format: "%@: Fenster %.0f × %.0f, Wechsel: Layout %.0f ms + Zeichnen %.0f ms, je Aktualisierung %.2f ms (Median)",
                       tag, host.frame.width, host.frame.height, (t1 - t0) * 1000, (t2 - t1) * 1000, updateCost(host)))
            sharpness(tag, host.layer!, px)
            let rows = views(host, NSTableView.self).filter { $0.numberOfRows > 0 }.map { "\(type(of: $0)) \(String(format: "%.0f", $0.rect(ofRow: 0).height))" }
            log("\(tag): Zeilenhöhen \(rows.joined(separator: " · "))")
            if let tv = views(host, NSTableView.self).first(where: { $0.numberOfRows > 100 }) {
                log("\(tag): Spalten " + tv.tableColumns.prefix(6).map { "\($0.title.isEmpty ? "·" : $0.title) \(Int($0.width))" }.joined(separator: " · "))
            }
            // AppKit-Ansichten (Wellenform, Zeichenflächen, Tabellen): Lage und Größe gegenüber der ersten Stufe
            let probes: [NSView] = views(host, WaveLayerNSView.self) + views(host, LiveCanvasView.self)
                + views(host, NSTableView.self).compactMap(\.enclosingScrollView)
            if n == 0 {
                for v in probes { reference[ObjectIdentifier(v)] = v.convert(v.bounds, to: nil) }
            } else {
                let k = z / first
                var worst = 0.0, worstName = "", count = 0
                for v in probes {
                    guard let r0 = reference[ObjectIdentifier(v)] else { continue }
                    count += 1
                    let r = v.convert(v.bounds, to: nil)
                    // Fenster-y zählt von unten: Abstand zur Oberkante vergleichen
                    let top0 = base.height * first - r0.maxY, top = base.height * z - r.maxY
                    let dev = max(abs(r.minX - r0.minX * k), abs(top - top0 * k), abs(r.width - r0.width * k), abs(r.height - r0.height * k)) / k
                    if dev > worst { worst = dev; worstName = "\(type(of: v)) bei \(Int(r0.minX)),\(Int(top0)) \(Int(r0.width))×\(Int(r0.height))" }
                }
                log(String(format: "%@: %d AppKit-Ansichten, größte Abweichung von ×%.2f: %.1f pt (%@)", tag, count, k, worst, worstName))
            }
            snapshot(host, scale: px, to: dir.appendingPathComponent("\(tag).png"))
        }
        // nur der Zoom ändert sich, das Fenster bleibt (wie ⌘+ / ⌘−)
        for z in [1.25, zooms.last ?? 1] {
            let t0 = CACurrentMediaTime()
            ZoomControl.apply(z)
            host.layoutSubtreeIfNeeded()
            let t1 = CACurrentMediaTime()
            CATransaction.flush()
            log(String(format: "nur Zoom -> %@ (Fenster bleibt): Layout %.0f ms + Zeichnen %.0f ms", ZoomSteps.percent(z), (t1 - t0) * 1000, (CACurrentMediaTime() - t1) * 1000))
            spin(1, step: pump)
        }
        log("PNGs in \(dir.path)")
        finish()
    }

    private static func spin(_ s: Double, step: () -> Void = {}, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !done() { step(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    /// Statusmeldung ändern -> SwiftUI-Aktualisierung + Layout + Übergabe an Core Animation
    private static func updateCost(_ v: NSView) -> Double {
        var t: [Double] = []
        for i in 0..<40 {
            StatusCenter.shared.post(.info, "Messung \(i)", key: "zoomshot")
            let t0 = CACurrentMediaTime()
            v.layoutSubtreeIfNeeded()
            CATransaction.flush()
            if i >= 5 { t.append((CACurrentMediaTime() - t0) * 1000) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return t.sorted()[t.count / 2]
    }

    /// gezeichnete Ebenen mit weniger Pixeln als das Fenster (unscharf); Bitmaps zählen nicht
    private static func sharpness(_ tag: String, _ root: CALayer, _ px: CGFloat) {
        var drawn = 0, soft = 0
        func visit(_ l: CALayer) {
            guard !l.isHidden else { return }
            if let c = l.contents, CFGetTypeID(c as CFTypeRef) != CGImage.typeID {
                drawn += 1
                if l.contentsScale < px * 0.98 { soft += 1 }
            }
            for x in l.sublayers ?? [] { visit(x) }
        }
        visit(root)
        log("\(tag): gezeichnete Ebenen \(drawn), unter Fensterauflösung \(soft)")
    }

    private static func views<T: NSView>(_ v: NSView, _ type: T.Type) -> [T] {
        var out: [T] = [], stack = [v]
        while let n = stack.popLast() { if let t = n as? T, !t.visibleRect.isEmpty { out.append(t) }; stack += n.subviews }
        return out
    }

    /// Ebenen-Baum rendern wie auf dem Bildschirm (Inhalte in ihrer echten Auflösung)
    private static func snapshot(_ v: NSView, scale: CGFloat, to url: URL) {
        guard let layer = v.layer else { return }
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if v.isFlipped {
            ctx.translateBy(x: 0, y: v.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url)
    }

    static func log(_ s: String) {
        print("[zoom] \(s)")
        fflush(stdout)
    }
}
