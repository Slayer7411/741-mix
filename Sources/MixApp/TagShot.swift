import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Selbsttest-Bild + Messung der Tag-Chips (MIX741_SELFTEST=1 MIX741_SHOT=tags:<ordner>), offscreen:
/// Browser-Bereich mit zwei gewählten und einem ausgeschlossenen Tag als PNG, Klicks auf Chip / neben den Chip
/// (Filter, Auswahl, Inline-Bearbeitung), Filterzeit, Blättern durch die Collection (ms je Seite) ohne Spalte,
/// mit schlichtem Text und mit Chips. Trennzeichen MIX741_SHOT_SEPS (Standard „·“), Tags MIX741_SHOT_TAGS („a|b“).
/// Collection nur gelesen, ohne Audio.
@MainActor
enum TagShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("tags:") else { return }
        run(String(spec.dropFirst("tags:".count)))
    }

    /// Fenster, das Klicks annimmt, ohne je gezeigt zu werden
    private final class ShotWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    static func run(_ path: String) -> Never {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        func log(_ s: String) { print("[tags] \(s)"); fflush(stdout) }
        // Run-Loop + Ereignisse (Klicks laufen über die Warteschlange, wie echte)
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() {
                if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(e)
                } else {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                }
            }
        }

        // Audio-Setup sichern (MixModel schreibt es beim Start zurück); nie das Interface einer laufenden Live-Session:
        // eingebaute Lautsprecher, stumm, Ausgabe sofort wieder aus
        let d = UserDefaults.standard
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1", "columns.Shot"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let restore = { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        d.setVolatileDomain(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                             "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.stop()
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        restore()
        mix.prefs.ui.previewMode = .off
        mix.prefs.ui.previewBackground = false
        mix.prefs.ui.tagHighlight = true
        let seps = env["MIX741_SHOT_SEPS"] ?? "·"
        mix.prefs.ui.tagSeparators = seps

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        browser.separators = { seps }
        store.load()
        spin(120) { !store.tracks.isEmpty }
        log("collection \(store.tracks.count) tracks · trennzeichen '\(seps)'")

        // Tags einmal zerlegen (kalt) und Filter über die ganze Collection
        let idx = BrowserPaneModel.tagIndex
        let t0 = CACurrentMediaTime()
        for t in store.tracks { _ = idx.entry(t.comment2, separators: seps) }
        log(String(format: "tags zerlegen: %.1f ms für %d tracks (%d verschiedene kommentar-2-texte)",
                   (CACurrentMediaTime() - t0) * 1000, store.tracks.count, idx.count))

        // zwei häufige Tags, die oft zusammen vorkommen, + ein dritter zum Ausschließen
        var freq: [String: Int] = [:]
        for t in store.tracks { for k in Set(idx.entry(t.comment2, separators: seps).tags) { freq[k, default: 0] += 1 } }
        let top = freq.sorted { $0.value > $1.value }.prefix(30).map(\.key)
        var pick: [String]
        if let s = env["MIX741_SHOT_TAGS"] {
            pick = s.split(separator: "|").map(String.init)
        } else {
            var best = (0, top.first ?? "", top.dropFirst().first ?? "")
            for (i, a) in top.enumerated() {
                for b in top[(i + 1)...] {
                    let n = store.tracks.filter { TagFilter(include: [a, b]).matches(keys: idx.entry($0.comment2, separators: seps).keys) }.count
                    if n > best.0 { best = (n, a, b) }
                }
            }
            pick = [best.1, best.2]
        }
        let both = TagFilter(include: Set(pick))
        let withBoth = store.tracks.filter { both.matches(keys: idx.entry($0.comment2, separators: seps).keys) }
        var co: [String: Int] = [:]
        for t in withBoth { for k in idx.entry(t.comment2, separators: seps).tags where !pick.contains(k) { co[k, default: 0] += 1 } }
        let exclude = co.filter { $0.value < withBoth.count }.max { $0.value < $1.value }?.key
        log("gewählt: \(pick.joined(separator: " + ")) (\(withBoth.count) tracks) · ausgeschlossen: \(exclude ?? "-")")

        let model = BrowserPaneModel(name: "Shot")
        model.showTree = false
        model.sortOrder = [KeyPathComparator(\Track.artist)]
        func filterTime(_ label: String) {
            var v: [Double] = []
            for i in 0..<6 {
                model.search = i.isMultiple(of: 2) ? "" : " "   // Zwischenspeicher der Zeilen umgehen
                let t = CACurrentMediaTime()
                _ = model.rows(from: store, history: history, separators: seps)
                v.append((CACurrentMediaTime() - t) * 1000)
            }
            model.search = ""
            log(String(format: "filter %@: %.2f ms (median, %d zeilen)", label, v.sorted()[v.count / 2], model.rows(from: store, history: history, separators: seps).count))
        }
        _ = model.rows(from: store, history: history, separators: seps)   // sortieren
        filterTime("ohne tags")
        model.tags = Set(pick)
        filterTime("2 tags")
        if let exclude { model.excludedTags = [exclude] }
        filterTime("2 tags + 1 ausgeschlossen")

        func host<V: View>(_ v: V, size: NSSize) -> (NSHostingView<AnyView>, NSWindow) {
            let view = AnyView(v
                .frame(width: size.width, height: size.height)
                .background(Theme.background)
                .environment(store).environment(mix).environment(browser).environment(history)
                .preferredColorScheme(.dark))
            let h = NSHostingView(rootView: view)
            h.appearance = NSAppearance(named: .darkAqua)
            let win = ShotWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = h
            h.frame = NSRect(origin: .zero, size: size)
            return (h, win)
        }
        @discardableResult func png(_ v: NSView, _ name: String) -> NSBitmapImageRep? {
            v.layoutSubtreeIfNeeded()
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            let url = dir.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            log("bild \(url.path)")
            return rep
        }
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView, t.tableColumns.count > 1 { return t }
            for s in v.subviews { if let t = table(s) { return t } }
            return nil
        }

        // Bild: echter Browser-Bereich (Kopf mit Filter + Liste)
        let (h, win) = host(BrowserPane(model: model), size: NSSize(width: 1400, height: 640))
        win.orderFrontRegardless()   // bei -20000/-20000: auf keinem Bildschirm sichtbar, nimmt aber Klicks an
        win.makeKey()
        for _ in 0..<8 { h.layoutSubtreeIfNeeded(); spin(0.2) }
        let shot = png(h, "tags-selected.png")

        // Klicks: auf den ersten Chip der ersten Zeile, neben die Chips, zweiter Klick daneben = Inline-Bearbeitung
        var ok = true
        if let tv = table(h), let col = tv.tableColumns.indices.first(where: { InlineEditController().field(ofColumn: $0, in: tv) == .comment2 }), tv.numberOfRows > 1 {
            var clickSerial = 100
            func click(_ p: NSPoint, flags: NSEvent.ModifierFlags = []) {
                let w = tv.convert(p, to: nil)
                clickSerial += 1
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: w, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: win.windowNumber, context: nil, eventNumber: clickSerial, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
                spin(0.15)
            }
            // Lage der Chips: berechnete x-Bereiche gegen das Bild (gewählter Chip hell gefüllt, Lücke dahinter nicht)
            if let shot, let cell = tv.view(atColumn: col, row: 0, makeIfNecessary: false) {
                let cvf = tv.convert(cell.bounds, from: cell)
                let tags0 = Self.tags(model.rows(from: store, history: history, separators: seps)[0], seps)
                let sx = CGFloat(shot.pixelsWide) / h.bounds.width
                func px(_ x: CGFloat) -> NSColor? {
                    let p = h.convert(NSPoint(x: cvf.minX + x, y: cvf.midY), from: tv)
                    let y = h.isFlipped ? p.y : h.bounds.height - p.y
                    return shot.colorAt(x: Int(p.x * sx), y: Int(y * sx))?.usingColorSpace(.sRGB)
                }
                func bright(_ c: NSColor?) -> Bool { (c?.brightnessComponent ?? 0) > 0.6 }
                var aligned = true
                for (i, sp) in TagChipsText.spans(tags: tags0).enumerated() where model.tagFilter.mark(tags0[i]) == .include && sp.upperBound + 3 < cvf.width {
                    // Ränder innen hell, Lücke rechts daneben dunkel
                    let inside = bright(px(sp.lowerBound + 1.5)) && bright(px(sp.upperBound - 1.5))
                    let gap = i == tags0.count - 1 || !bright(px(sp.upperBound + 2.5))
                    log(String(format: "chip „%@“ %.1f…%.1f: innen hell %@, lücke dunkel %@", tags0[i], sp.lowerBound, sp.upperBound, inside ? "ja" : "NEIN", gap ? "ja" : "NEIN"))
                    aligned = aligned && inside && gap
                }
                ok = ok && aligned
                // Klick mitten auf den letzten Chip -> genau dieser Tag
                let spans0 = TagChipsText.spans(tags: tags0)
                if let n = spans0.lastIndex(where: { $0.upperBound <= cvf.width }) {
                    let sp = spans0[n], last = tags0[n]
                    let f0 = model.tagFilter
                    click(NSPoint(x: cvf.minX + (sp.lowerBound + sp.upperBound) / 2, y: cvf.midY))
                    let hit = model.tagFilter.mark(last) != f0.mark(last)
                    log("klick mitten auf den letzten ganz sichtbaren chip „\(last)“: \(hit ? "umgeschaltet" : "NICHT umgeschaltet")")
                    ok = ok && hit
                    model.tags = Set(pick)
                    model.excludedTags = exclude.map { [$0] } ?? []
                    for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.1) }
                }
            }
            let before = model.tagFilter
            let row0 = tv.frameOfCell(atColumn: col, row: 0)
            let first = Self.tags(model.rows(from: store, history: history, separators: seps)[0], seps).first ?? ""
            // Chip 1 beginnt am linken Rand der Zelle
            click(NSPoint(x: row0.minX + 6, y: row0.midY))
            let afterChip = model.tagFilter
            let chipOK = afterChip != before && afterChip.mark(first) == (before.mark(first) == .include ? .none : .include)
            log("klick auf chip „\(first)“: filter \(chipOK ? "umgeschaltet" : "NICHT umgeschaltet") · auswahl \(model.selection.count) · ein=\(afterChip.include.sorted()) aus=\(afterChip.exclude.sorted())")
            ok = ok && chipOK
            click(NSPoint(x: row0.minX + 6, y: row0.midY))   // zurück
            log("zweiter klick: filter \(model.tagFilter == before ? "wie vorher" : "ANDERS")")
            ok = ok && model.tagFilter == before
            for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.1) }
            // ⌥-Klick auf einen nicht gewählten Chip -> ausgeschlossen
            let rows = model.rows(from: store, history: history, separators: seps)
            if let r = rows.prefix(30).firstIndex(where: { Self.tags($0, seps).first.map { model.tagFilter.mark($0) == .none } ?? false }) {
                let tag = Self.tags(rows[r], seps)[0]
                let c = tv.frameOfCell(atColumn: col, row: r)
                click(NSPoint(x: c.minX + 6, y: c.midY), flags: .option)
                let ex = model.tagFilter.mark(tag) == .exclude
                log("⌥-klick auf „\(tag)“: \(ex ? "ausgeschlossen" : "NICHT ausgeschlossen")")
                ok = ok && ex
                model.removeTag(tag)
                for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.1) }
            }
            // neben die Chips (Zeile mit Platz hinter dem letzten Chip): Auswahl, dann zweiter Klick -> Inline-Bearbeitung
            tv.tableColumns[col].width = 480   // Platz hinter den Chips, Spalte Comment dafür aus
            if let c = tv.tableColumns.indices.first(where: { InlineEditController().field(ofColumn: $0, in: tv) == .comment }) { tv.tableColumns[c].isHidden = true }
            for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.1) }
            let rowsNow = model.rows(from: store, history: history, separators: seps)
            var emptyRow = 1, empty = NSPoint.zero
            for r in 1..<min(rowsNow.count, 20) {
                guard let cell = tv.view(atColumn: col, row: r, makeIfNecessary: false) else { continue }
                let cvf = tv.convert(cell.bounds, from: cell)
                let end = TagChipsText.spans(tags: Self.tags(rowsNow[r], seps)).last?.upperBound ?? 0
                if end + 12 < cvf.width, cvf.minX + (end + cvf.width) / 2 < tv.visibleRect.maxX - 4 { emptyRow = r; empty = NSPoint(x: cvf.minX + (end + cvf.width) / 2, y: cvf.midY); break }
            }
            let key1 = rowsNow[emptyRow].key
            log("leere stelle: zeile \(emptyRow + 1) bei \(empty) · zeile laut tabelle \(tv.row(at: empty)) spalte \(tv.column(at: empty))")
            click(empty)
            spin(NSEvent.doubleClickInterval + 0.2)
            let selOK = model.tagFilter == before
            log("klick neben die chips: filter unverändert \(selOK) · auswahl \(model.selection == [key1] ? "zeile \(emptyRow + 1)" : "nicht übernommen (offscreen) -> gesetzt")")
            if model.selection != [key1] { model.selection = [key1]; spin(0.2) }
            click(empty)
            spin(NSEvent.doubleClickInterval + 0.3)
            let editOK = model.inline?.key == key1 && model.inline?.field == .comment2
            log("zweiter klick neben die chips: inline-bearbeitung \(editOK ? "kommentar 2" : "NICHT gestartet (\(String(describing: model.inline?.field)))")")
            ok = ok && selOK && editOK
            model.inline = nil   // nichts übernehmen
            // Chip in der gewählten Zeile: Filter statt Bearbeitung
            let c1 = tv.frameOfCell(atColumn: col, row: emptyRow)
            let f1 = model.tagFilter
            click(NSPoint(x: c1.minX + 6, y: c1.midY))
            spin(NSEvent.doubleClickInterval + 0.3)
            let noEdit = model.inline == nil && model.tagFilter != f1
            log("klick auf chip der gewählten zeile: \(noEdit ? "filter, keine bearbeitung" : "FEHLER (inline \(model.inline != nil), filter gleich \(model.tagFilter == f1))")")
            ok = ok && noEdit
            model.inline = nil
            model.tags = Set(pick)
            model.excludedTags = exclude.map { [$0] } ?? []
        } else {
            log("keine tabelle / spalte comment2")
            ok = false
        }
        win.contentView = nil
        win.close()

        // Blättern durch die Collection: ms je Seite (Scrollen + Layout + Zeichnen)
        let all = store.tracks.sorted { $0.artist < $1.artist }
        let pagesN = Int(env["MIX741_SHOT_PAGES"] ?? "") ?? 60
        func pages(_ label: String, _ h: NSView, _ tv: NSTableView) -> (Double, Double) {
            var out: [Double] = [], lay: [Double] = []
            for p in 0..<pagesN {
                let row = min(all.count - 1, p * (all.count / pagesN))
                let t0 = CACurrentMediaTime()
                tv.scrollRowToVisible(row)
                tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: row).minY))
                h.layoutSubtreeIfNeeded()
                let t1 = CACurrentMediaTime()
                h.display()
                CATransaction.flush()   // Ebenen zeichnen + übergeben wie im Display-Zyklus
                out.append((CACurrentMediaTime() - t0) * 1000)
                lay.append((t1 - t0) * 1000)
                spin(0.03)
            }
            let s = out.sorted(), l = lay.sorted()
            log(String(format: "%@: %d seiten · median %.1f ms (davon scrollen+layout %.1f), p90 %.1f ms, max %.1f ms",
                       label, pagesN, s[s.count / 2], l[l.count / 2], s[Int(Double(s.count) * 0.9)], s.last ?? 0))
            return (s[s.count / 2], s[Int(Double(s.count) * 0.9)])
        }
        // nur die Spalte: 40 Zellen je Seite (eine Bildschirmseite), Layout + Zeichnen, schlichter Text gegen Chips
        let withTags = all.filter { !$0.comment2.isEmpty }
        func column(_ label: String, _ mark: TagFilter?) {
            let cells = NSHostingView(rootView: AnyView(EmptyView()))
            cells.frame = NSRect(x: 0, y: 0, width: 420, height: 40 * 17)
            var out: [Double] = []
            for round in 0..<2 {
                for p in 0..<pagesN {
                    let page = Array(withTags[min(withTags.count - 40, p * (withTags.count / pagesN))...].prefix(40))
                    let t0 = CACurrentMediaTime()
                    cells.rootView = AnyView(VStack(alignment: .leading, spacing: 0) {
                        ForEach(page) { t in
                            Group {
                                if let mark {
                                    let e = BrowserPaneModel.tagIndex.entry(t.comment2, separators: seps)
                                    TagChipsText(tags: e.tags, keys: e.keys, ui: mix.prefs.ui, filter: mark)
                                } else {
                                    Text(t.comment2)
                                }
                            }
                            .frame(width: 420, height: 17, alignment: .leading).clipped()
                        }
                    }.font(Theme.mono(11)).environment(\.colorScheme, .dark))
                    cells.layoutSubtreeIfNeeded()
                    cells.display()
                    CATransaction.flush()
                    if round == 1 { out.append((CACurrentMediaTime() - t0) * 1000) }
                }
            }
            let s = out.sorted()
            log(String(format: "spalte allein · %@: 40 zellen je seite · median %.2f ms (%.0f µs je zelle), p90 %.2f ms", label,
                       s[s.count / 2], s[s.count / 2] * 1000 / 40, s[Int(Double(s.count) * 0.9)]))
        }
        column("schlichter text", nil)
        column("chips", TagFilter())
        column("chips, 2 tags markiert", TagFilter(include: Set(pick)))

        let variants: [(String, Bool, Bool, TagFilter)] = [
            ("schlichter text", true, true, TagFilter()),
            ("chips", true, false, TagFilter()),
            ("chips, 2 tags markiert", true, false, TagFilter(include: Set(pick))),
        ]
        for round in 0..<3 {
            for (label, visible, plain, mark) in (round == 1 ? variants.reversed() : variants) {
                TagChips.benchPlain = plain
                // Markierung ohne Filter: alle Zeilen, nur die Chips zeigen die gewählten Tags
                let m = BrowserPaneModel(name: "Shot")
                m.tags = mark.include
                let (h, win) = host(TrackTable(rows: all, model: m), size: NSSize(width: 1400, height: 1000))
                for _ in 0..<6 { h.layoutSubtreeIfNeeded(); spin(0.2) }
                guard let tv = table(h) else { log("keine tabelle"); break }
                if let c = tv.tableColumns.indices.first(where: { InlineEditController().field(ofColumn: $0, in: tv) == .comment2 }) {
                    tv.tableColumns[c].isHidden = !visible
                }
                h.layoutSubtreeIfNeeded()
                _ = pages("\(round == 0 ? "aufwärmen" : "messen") · \(label)", h, tv)
                win.contentView = nil
                win.close()
            }
        }
        TagChips.benchPlain = false
        restore()
        log(ok ? "OK" : "FEHLER")
        exit(ok ? 0 : 1)
    }

    private static func tags(_ t: Track, _ seps: String) -> [String] { BrowserPaneModel.tagIndex.entry(t.comment2, separators: seps).tags }
}
