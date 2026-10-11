import AppKit
import QuartzCore
import SwiftUI
import MixCore

/// Selbsttest-Bilder + Messung der Browser-Vorschau (MIX741_SELFTEST=1 MIX741_SHOT=preview:<ordner>), offscreen:
/// N Tracks der Collection (MIX741_SHOT_N, Standard 40) per Stapel berechnen (Durchsatz), die echte Track-Tabelle in
/// beiden Modi als PNG, dann Blättern durch die ganze Collection (ms je Seite: aus / kalt / aus dem Cache).
/// Collection nur gelesen, Übersichten in einen eigenen Ordner (MIX741_OVERVIEW_DIR, sonst temporär), Audio stumm.
@MainActor
enum PreviewShot {
    static func run(_ spec: String) -> Never {
        let dir = URL(fileURLWithPath: String(spec.dropFirst("preview:".count)), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        func log(_ s: String) { print("[preview] \(s)"); fflush(stdout) }
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // Audio-Setup sichern (MixModel schreibt es beim Start zurück), nur eingebaute Lautsprecher, stumm
        let d = UserDefaults.standard
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1", "columns.Shot"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let restore = { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        restore()
        mix.prefs.ui.previewMode = .column

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        store.load()
        spin(120) { !store.tracks.isEmpty }
        let ov = Overviews.shared
        spin(30) { ov.loaded }
        log("collection \(store.tracks.count) tracks · cache \(Overviews.directory.path) (\(ov.store.count) vorhanden)")

        // Stapel: N Tracks mit Grid, neueste zuerst
        let n = Int(env["MIX741_SHOT_N"] ?? "") ?? 40
        if let w = Int(env["MIX741_SHOT_WORKERS"] ?? "") { ov.jobs.maxWorkers = w }
        let pick = store.tracks.filter { $0.fileExists && !$0.loose && $0.bpm > 0 && $0.gridAnchorMs != nil }
            .sorted { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
            .prefix(n)
        let missing = pick.filter { !ov.store.contains($0.key) }
        let t0 = CACurrentMediaTime()
        ov.enqueue(Array(pick))
        spin(1800) { ov.jobs.isIdle }
        let secs = CACurrentMediaTime() - t0
        let made = pick.filter { ov.store.contains($0.key) }.count
        let minutes = pick.reduce(0) { $0 + $1.duration } / 60
        log(String(format: "stapel: %d tracks (%d neu, %.0f min audio) in %.1f s, %d worker -> %.0f tracks/min, %d mit übersicht",
                   pick.count, missing.count, minutes, secs, ov.jobs.maxWorkers, Double(missing.count) / max(secs, 0.001) * 60, made))
        ov.store.flush()
        let file = Overviews.directory.appendingPathComponent("overviews.bin")
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        log(String(format: "cache-datei: %d einträge, %.1f KB (%.2f KB je track)", ov.store.count, Double(bytes) / 1024, Double(bytes) / 1024 / Double(max(1, ov.store.count))))

        // Zeichnen ohne Tabelle: 50 Bilder kalt (mit Übersicht) und aus dem Cache
        let specs = pick.prefix(50).map { PreviewSpec($0, mix: mix) }
        let overviews = specs.map { ov.store.overview($0.key, path: $0.path) }
        var imgs: [CGImage?] = [], cold = 0.0
        for _ in 0..<3 {   // erster Durchlauf wärmt CoreGraphics an, gemeldet wird der letzte
            let t0 = CACurrentMediaTime()
            imgs = zip(specs, overviews).map { PreviewRenderer.render($0, overview: $1) }
            cold = CACurrentMediaTime() - t0
        }
        var t = CACurrentMediaTime()
        for (s, i) in zip(specs, imgs) { if let i { PreviewImages.cache.setObject(i, forKey: NSNumber(value: s.hashValue), cost: i.bytesPerRow * i.height) } }
        t = CACurrentMediaTime()
        var hits = 0
        for s in specs { if PreviewImages.cached(PreviewSpec(pick.first { $0.key == s.key }!, mix: mix).hashValue) != nil { hits += 1 } }
        let warm = CACurrentMediaTime() - t
        log(String(format: "50 vorschauen zeichnen: %.2f ms (%.3f ms je bild) · aus dem cache inkl. spec: %.2f ms (%d treffer)",
                   cold * 1000, cold * 1000 / 50, warm * 1000, hits))

        // echte Track-Tabelle offscreen
        let model = BrowserPaneModel(name: "Shot")
        func host(_ rows: [Track], size: NSSize) -> (NSHostingView<AnyView>, NSWindow) {
            let view = AnyView(TrackTable(rows: rows, generation: 0, model: model)
                .frame(width: size.width, height: size.height)
                .background(Theme.background)
                .environment(store).environment(mix).environment(browser).environment(history)
                .preferredColorScheme(.dark))
            let h = NSHostingView(rootView: view)
            h.appearance = NSAppearance(named: .darkAqua)
            let win = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = h
            h.frame = NSRect(origin: .zero, size: size)
            return (h, win)
        }
        func png(_ v: NSView, _ name: String) {
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = dir.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log("bild \(url.path)")
        }
        let shotRows = Array(pick.prefix(28))
        // Schnitt (nur im Speicher: der Selbsttest schreibt edits.json nie): Zeile 2 Anfang + Ende, Zeile 3 nur Ende
        if shotRows.count > 2 {
            let a = shotRows[1], b = shotRows[2]
            mix.edits.set(TrackEdit(trim: TrackTrim(start: a.duration * 0.2, end: a.duration * 0.75)), for: a.key)
            mix.edits.set(TrackEdit(trim: TrackTrim(end: b.duration * 0.6)), for: b.key)
            log("schnitt: zeile 2 20–75 %, zeile 3 bis 60 %")
        }
        for (mode, name) in [(PreviewMode.fullRow, "preview-row.png"), (.column, "preview-column.png"), (.behindTitle, "preview-title.png")] {
            mix.prefs.ui.previewMode = mode
            let (h, win) = host(shotRows, size: NSSize(width: 1400, height: 640))
            for _ in 0..<8 { h.layoutSubtreeIfNeeded(); spin(0.25) }
            png(h, name)
            // ganze Zeile: Auswahl (Zeile 2) und Inline-Bearbeitung (Titel, Zeile 4) prüfen
            if mode != .behindTitle, shotRows.count > 4 {
                model.selection = [shotRows[3].key]
                model.inlineText = shotRows[3].title
                model.inline = InlineEdit(key: shotRows[3].key, field: .title, serial: 1)
                for _ in 0..<6 { h.layoutSubtreeIfNeeded(); spin(0.25) }
                png(h, mode == .fullRow ? "preview-row-edit.png" : "preview-column-edit.png")
                model.inline = nil
                model.selection = []
            }
            win.contentView = nil
            win.close()
        }

        // Blättern durch die ganze Collection: ms je Seite (Scrollen + Layout + Zeichnen), Vorschau aus / an
        let all = store.tracks.sorted { $0.artist < $1.artist }
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView, t.tableColumns.count > 1 { return t }
            for s in v.subviews { if let t = table(s) { return t } }
            return nil
        }
        func pages(_ label: String, _ h: NSView, _ tv: NSTableView, count: Int) -> [Double] {
            var out: [Double] = []
            let per = max(1, Int(tv.visibleRect.height / max(1, tv.rowHeight + tv.intercellSpacing.height)))
            for p in 0..<count {
                let row = min(all.count - 1, p * (all.count / count))
                let t0 = CACurrentMediaTime()
                tv.scrollRowToVisible(row)
                tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: row).minY))
                h.layoutSubtreeIfNeeded()
                h.display()
                out.append((CACurrentMediaTime() - t0) * 1000)
                spin(0.03)
            }
            let s = out.sorted()
            log(String(format: "%@: %d seiten à ~%d zeilen · median %.1f ms, p90 %.1f ms, max %.1f ms",
                       label, count, per, s[s.count / 2], s[Int(Double(s.count) * 0.9)], s.last ?? 0))
            return out
        }
        let pagesN = Int(env["MIX741_SHOT_PAGES"] ?? "") ?? 60
        for mode in [PreviewMode.off, .column, .behindTitle, .fullRow] {
            mix.prefs.ui.previewMode = mode
            let (h, win) = host(all, size: NSSize(width: 1400, height: 1000))
            for _ in 0..<6 { h.layoutSubtreeIfNeeded(); spin(0.2) }
            guard let tv = table(h) else { log("keine tabelle gefunden"); break }
            log("tabelle: \(tv.numberOfRows) zeilen, zeilenhöhe \(tv.rowHeight) pt, \(tv.tableColumns.count) spalten")
            if mode == .off {
                _ = pages("aus", h, tv, count: pagesN)
            } else {
                _ = pages("\(mode.rawValue.lowercased()) kalt", h, tv, count: pagesN)
                spin(1.5)   // Bilder im Hintergrund fertig
                _ = pages("\(mode.rawValue.lowercased()) aus dem cache", h, tv, count: pagesN)
                if mode == .column { png(h, "preview-collection.png") }
                if mode == .fullRow { png(h, "preview-collection-row.png") }
            }
            win.contentView = nil
            win.close()
        }
        restore()
        if env["MIX741_OVERVIEW_DIR"] == nil { try? FileManager.default.removeItem(at: Overviews.directory) }
        exit(0)
    }
}
