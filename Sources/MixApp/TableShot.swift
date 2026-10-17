import AppKit
import QuartzCore
import SwiftUI
import MixCore

/// Selbsttest-Bilder der Track-Tabelle (MIX741_SELFTEST=1 MIX741_SHOT=table:<ordner>), offscreen, ohne Audio:
/// Browser-Bereich je Vorschau-Modus als PNG (mit Auswahl und Inline-Bearbeitung), Kennzahlen der Tabelle (Zeilenhöhe,
/// Abstände, Kopf, Spalten) ins Protokoll, Harmonie-Bilder mit festem Bezug (MIX741_SHOT_KEY=<key>@<bpm>).
/// MIX741_SHOT_COLUMNS=<json>: Spalten-Anordnung (Format von `columns.*`),
/// nur flüchtig für diesen Prozess. Collection nur gelesen, keine Einstellungen geschrieben.
@MainActor
enum TableShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("table:") else { return }
        run(String(spec.dropFirst("table:".count)))
    }

    private final class ShotWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// Pixel der Zeile (Gerätepixel 1×) als RGBA
    private static func pixels(_ v: NSView) -> (NSBitmapImageRep, (CGFloat, CGFloat) -> (CGFloat, CGFloat, CGFloat))? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        return (rep, { x, y in
            // Zeile ist gespiegelt (y nach unten), das Bitmap auch (Zeile 0 oben)
            // über dem Hintergrund der Tabelle (Void) zusammengesetzt: Zeilen füllen mit Deckung
            let c = rep.colorAt(x: Int(x * sx), y: Int(y * sy))?.usingColorSpace(.sRGB) ?? .black
            let v = TableStyle.void.usingColorSpace(.sRGB) ?? .black, a = c.alphaComponent
            return (c.redComponent * a + v.redComponent * (1 - a), c.greenComponent * a + v.greenComponent * (1 - a), c.blueComponent * a + v.blueComponent * (1 - a))
        })
    }

    /// Zweizeilig: Sammelspalte statt der Textspalten, Zeilenhöhe, beide Textzeilen gezeichnet, schmale Spalten mittig,
    /// Sortierung über den Kopf der Sammelspalte, Return/Tab durch ihre Felder, Detailleiste folgt der Auswahl (Zeit je
    /// Wechsel), Auswahlfarbe und Streifen
    static func twoLineChecks(_ tv: NSTableView, _ pane: BrowserPaneModel, _ h: NSView, _ settle: () -> Void,
                              _ check: (String, Bool) -> Void, _ log: (String) -> Void) {
        guard let ctl = tv.delegate as? TrackTableController, let mix = ctl.mix else { check("zweizeilig: controller", false); return }
        let single = tv.rowHeight
        pane.twoLine = true
        pane.detailBar = true
        settle(); settle()
        func col(_ id: String) -> NSTableColumn? { tv.tableColumns.first { $0.identifier.rawValue == id } }
        let shown = tv.tableColumns.filter { !$0.isHidden }.map(\.identifier.rawValue)
        check("zweizeilig: sammelspalte", col("track")?.isHidden == false && ["title", "artist", "comment", "comment2", "label"].allSatisfy { col($0)?.isHidden == true })
        let want = TableStyle.rowHeight(mix.prefs.ui, twoText: true)
        log(String(format: "zweizeilig: zeile %.0f pt (einzeilig %.0f) · spalten %@", tv.rowHeight, single, shown.joined(separator: ",")))
        check("zweizeilig: zeilenhöhe", tv.rowHeight == want && tv.rowHeight >= single * 1.3 && tv.rowHeight <= single * 1.8)
        // Zeile mit Titel und Kommentar (beide Zeilen haben Text)
        guard let r = pane.shown.indices.prefix(4000).first(where: { pane.shown[$0].title.count > 4 && pane.shown[$0].comment.count > 4 && pane.shown[$0].bpm > 0 }),
              let ti = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "track" }),
              let bi = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "bpm" }) else { check("zweizeilig: testzeile", false); return }
        tv.scrollRowToVisible(r)
        pane.selection = []
        settle()
        let cell = tv.frameOfCell(atColumn: ti, row: r), row = tv.rect(ofRow: r)
        let lines = ctl.trackLines(cell)
        check("zweizeilig: zeilen in der zelle", lines[0].minY >= row.minY && lines[1].maxY <= row.maxY && lines[1].minY >= lines[0].maxY - 0.5)
        if let rv = tv.rowView(atRow: r, makeIfNecessary: false), let (_, px) = pixels(rv) {
            func ink(_ l: CGRect) -> Int {
                var n = 0
                for x in stride(from: l.minX - row.minX + 1, to: min(l.maxX - row.minX, l.minX - row.minX + 300), by: 1) {
                    for y in stride(from: l.minY - row.minY + 2, to: l.maxY - row.minY - 1, by: 1) { let c = px(x, y); if c.0 + c.1 + c.2 > 1.2 { n += 1 } }
                }
                return n
            }
            let a = ink(lines[0]), b = ink(lines[1])
            log("zweizeilig: helle pixel zeile 1 \(a), zeile 2 \(b)")
            check("zweizeilig: beide zeilen sichtbar", a > 20 && b > 20)
        }
        let bpm = tv.frameOfCell(atColumn: bi, row: r)
        check("zweizeilig: schmale spalten mittig", abs(bpm.midY - row.midY) < 1)
        // Kopf der Sammelspalte sortiert nach dem Titel, Kopf-Menü wählt Artist
        // Kopf der Sammelspalte: sortiert nach ihrem Teil (bisher Artist), Kopf-Menü wählt den Titel
        let partPaths = TrackPart.sortable.compactMap { $0.sort?.keyPath }
        tv.sortDescriptors = [NSSortDescriptor(key: "track", ascending: false)] + tv.sortDescriptors.filter { $0.key != "track" }
        settle()
        check("zweizeilig: sortieren über track", pane.sortOrder.first.map { partPaths.contains($0.keyPath) && $0.order == .reverse } == true)
        if let menu = tv.headerView?.menu {
            menu.delegate?.menuNeedsUpdate?(menu)
            let head = menu.items.firstIndex { $0.title == String(localized: "Spalte Track sortieren nach") } ?? 999
            if let item = menu.items.enumerated().first(where: { $0.offset > head && $0.element.title == TrackPart.title.name })?.element,
               let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }
            settle()
            check("zweizeilig: kopf-menü titel", pane.sortOrder.first?.keyPath == \Track.title && tv.sortDescriptors.first?.key == "track")
        }
        // Return: erstes Feld der Sammelspalte (Titel), Tab: Artist
        let key = pane.shown[r].key
        pane.selection = [key]
        settle()
        // nach dem Sortieren steht der Track woanders: sichtbar machen (wie die Tabelle nach einer neuen Liste)
        let r2 = pane.shown.firstIndex { $0.key == key } ?? r
        tv.scrollRowToVisible(r2)
        settle()
        ctl.inline?.beginFromKeyboard([key])
        settle()
        let ed = pane.inline
        let editorShown = tv.subviews.contains { $0 is NSTableRowView && $0.subviews.contains { $0 is InlineFieldCell } }
        if let ed { ctl.inline?.finish(ed, commit: false, move: 1) }
        settle()
        let order = ctl.trackFields
        let next = ed.flatMap { e in order.firstIndex(of: e.field).map { $0 + 1 < order.count ? order[$0 + 1] : nil } } ?? nil
        log("zweizeilig: return -> \(ed?.field.rawValue ?? "-") (feld da: \(editorShown)), tab -> \(pane.inline?.field.rawValue ?? "-") · reihenfolge \(order.map(\.rawValue))")
        check("zweizeilig: return/tab", ed.map { order.contains($0.field) } == true && editorShown && next != nil && pane.inline?.field == next)
        if let e = pane.inline { ctl.inline?.finish(e, commit: false, move: 0) }
        settle()
        // Detailleiste: Auswahl Schritt für Schritt, Zeit je Wechsel (Auswahl + Zeichnen der Leiste)
        guard let bar = pane.detail else { check("detailleiste da", false); return }
        check("detailleiste zeigt auswahl", bar.track?.key == key)
        var ms: [Double] = []
        for i in 1...30 {
            let k = pane.shown[(r + i) % pane.shown.count].key
            let t0 = CACurrentMediaTime()
            pane.selection = [k]
            ctl.listArrived()
            bar.display()
            ms.append((CACurrentMediaTime() - t0) * 1000)
            if bar.track?.key != k { check("detailleiste folgt", false); break }
        }
        ms.sort()
        log(String(format: "detailleiste: wechsel median %.2f ms · max %.2f ms · zeichnen %.2f ms", ms[ms.count / 2], ms.last ?? 0, bar.lastMs))
        check("detailleiste < 2 ms", ms[ms.count / 2] < 2)
        // Auswahlfarbe: Streifen links voll rot, Fläche rot getönt
        pane.selection = [key]
        settle()
        tv.scrollRowToVisible(r2)
        settle()
        if let rv = tv.rowView(atRow: r2, makeIfNecessary: false), let (_, px) = pixels(rv) {
            let stripe = px(0.5, rv.bounds.midY), area = px(rv.bounds.width - 30, 2)
            log(String(format: "auswahl: streifen %.2f/%.2f/%.2f · fläche %.2f/%.2f/%.2f", stripe.0, stripe.1, stripe.2, area.0, area.1, area.2))
            check("auswahl: streifen und fläche", stripe.0 > 0.7 && stripe.0 > stripe.1 + 0.4 && area.0 > area.1 + 0.05 && area.0 < 0.4)
        }
        pane.selection = []
        pane.twoLine = nil
        pane.detailBar = nil
        settle()
        check("zurück einzeilig", col("track")?.isHidden == true && col("title")?.isHidden == false && tv.rowHeight == single)
    }

    static func run(_ path: String) -> Never {
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let env = ProcessInfo.processInfo.environment
        func log(_ s: String) { print("[table] \(s)"); fflush(stdout) }
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // Audio-Modell ohne Ton (Gerät sofort frei), Setup danach zurück; Spalten nur flüchtig
        let d = E2E.defaults
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        var volatile: [String: Any] = ["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0]
        if let f = env["MIX741_SHOT_COLUMNS"], let data = FileManager.default.contents(atPath: f) { volatile["columns.TableShot"] = data }
        d.setVolatileDomain(volatile, forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.stop()
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        mix.prefs.ui.tagSeparators = env["MIX741_SHOT_SEPS"] ?? mix.prefs.ui.tagSeparators

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        store.load()
        spin(120) { !store.tracks.isEmpty }
        spin(30) { Overviews.shared.loaded }
        log("collection \(store.tracks.count) tracks")

        let pane = BrowserPaneModel(name: "TableShot")
        pane.showTree = false
        browser.separators = { mix.prefs.ui.tagSeparators }

        func host(size: NSSize, model: BrowserPaneModel? = nil) -> (NSHostingView<AnyView>, NSWindow) {
            let view = AnyView(BrowserPane(model: model ?? pane)
                .frame(width: size.width, height: size.height)
                .background(Theme.background)
                .foregroundStyle(Theme.bone)
                .tint(Theme.state)
                .environment(store).environment(mix).environment(browser).environment(history)
                .preferredColorScheme(.dark))
            let h = NSHostingView(rootView: view)
            h.appearance = NSAppearance(named: .darkAqua)
            let win = ShotWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = h
            h.frame = NSRect(origin: .zero, size: size)
            win.orderFrontRegardless()
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
        func table(_ v: NSView) -> NSTableView? {
            if let t = v as? NSTableView, t.tableColumns.count > 1 { return t }
            for s in v.subviews { if let t = table(s) { return t } }
            return nil
        }
        func describe(_ tv: NSTableView) {
            let sv = tv.enclosingScrollView
            log("klasse \(type(of: tv)) · zeilen \(tv.numberOfRows) · rowHeight \(tv.rowHeight) · zeile 0 \(tv.numberOfRows > 0 ? NSStringFromRect(tv.rect(ofRow: 0)) : "-") · intercell \(NSStringFromSize(tv.intercellSpacing))")
            log("style \(tv.style.rawValue) · grid \(tv.gridStyleMask.rawValue) · auswahl-stil \(tv.selectionHighlightStyle.rawValue) · hintergrund \(tv.backgroundColor) · abwechselnd \(tv.usesAlternatingRowBackgroundColors)")
            log("typeSelect \(tv.allowsTypeSelect) · reorder \(tv.allowsColumnReordering) · resize \(tv.allowsColumnResizing) · mehrfach \(tv.allowsMultipleSelection) · leer \(tv.allowsEmptySelection) · autoresize \(tv.columnAutoresizingStyle.rawValue) · rowSizeStyle \(tv.rowSizeStyle.rawValue) · floatsGroupRows \(tv.floatsGroupRows)")
            log("kopf \(tv.headerView.map { NSStringFromRect($0.frame) } ?? "-") · scroll: horizontal \(sv?.hasHorizontalScroller ?? false) · autohide \(sv?.autohidesScrollers ?? false) · scroller-stil \(sv?.scrollerStyle.rawValue ?? -1) · insets \(sv.map { "\($0.contentInsets)" } ?? "-") · zeichnet hintergrund \(sv?.drawsBackground ?? false)")
            for c in tv.tableColumns {
                log(String(format: "spalte %@ „%@“ breite %.1f (min %.1f, max %.1f)%@ maske %d sort %@ kopf-schrift %@",
                           c.identifier.rawValue, c.title, c.width, c.minWidth, c.maxWidth, c.isHidden ? " versteckt" : "",
                           c.resizingMask.rawValue, c.sortDescriptorPrototype?.key ?? "-", c.headerCell.font?.fontName ?? "-"))
            }
            if tv.numberOfRows > 0, let rv = tv.rowView(atRow: 0, makeIfNecessary: false) {
                log("zeilen-ansicht \(type(of: rv)) · \(NSStringFromRect(rv.frame)) · emphasized \(rv.isEmphasized) · hintergrund \(rv.backgroundColor)")
                for (i, c) in tv.tableColumns.enumerated() where !c.isHidden {
                    let v = tv.view(atColumn: i, row: 0, makeIfNecessary: false)
                    log("  zelle \(c.identifier.rawValue): \(v.map { "\(type(of: $0))" } ?? "gezeichnet") \(NSStringFromRect(tv.frameOfCell(atColumn: i, row: 0)))")
                }
            }
        }

        // MIX741_SHOT_METRICS=1: Zeilenhöhe je Zoom, Modus und Schriftgröße (nur Protokoll)
        if env["MIX741_SHOT_METRICS"] == "1" {
            for z in [1.0, 1.25, 1.5, 2.0] {
                UIZoom.shared.factor = z
                for (mode, size) in [(PreviewMode.off, 12.0), (.column, 12), (.fullRow, 11), (.fullRow, 12), (.fullRow, 13), (.fullRow, 14)] {
                    mix.prefs.ui.previewMode = mode
                    mix.prefs.ui.previewTextSize = size
                    let (h, win) = host(size: NSSize(width: 1400, height: 400))
                    for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.15) }
                    if let tv = table(h), tv.numberOfRows > 2 {
                        let hdr = tv.headerView?.frame.height ?? 0
                        log("zoom \(z) \(mode) \(size) pt: zeile \(tv.rect(ofRow: 1).height) · kopf \(hdr) · intercell \(NSStringFromSize(tv.intercellSpacing)) · spalte 0 x \(tv.rect(ofColumn: 0).minX)")
                    }
                    win.contentView = nil
                    win.close()
                }
            }
            exit(0)
        }

        // MIX741_SHOT_CHECKS=1: Verhalten der Tabelle ohne Maus (Sortierung, Auswahl, Encoder, Return, Spalten, Listenwechsel)
        if env["MIX741_SHOT_CHECKS"] == "1" {
            var ok = true
            func check(_ name: String, _ pass: Bool) { log("prüfung \(name): \(pass ? "ok" : "FEHLER")"); ok = ok && pass }
            mix.prefs.ui.previewMode = .off
            // Bereich A des Browsers (Ziel von Encoder und Controller)
            let pane = browser.paneA
            pane.showTree = false
            let (h, win) = host(size: NSSize(width: 1400, height: 640), model: pane)
            func settle() { for _ in 0..<6 { h.layoutSubtreeIfNeeded(); spin(0.1) } }
            settle()
            guard let tv = table(h) else { log("keine tabelle"); exit(1) }
            check("zeilen = liste", tv.numberOfRows == pane.shown.count && tv.numberOfRows == store.tracks.count)
            // Spaltenkopf: Sortierung nach Titel, dann absteigend
            tv.sortDescriptors = [NSSortDescriptor(key: "title", ascending: true)]
            settle(); spin(0.3); settle()
            check("sortieren titel", pane.sortOrder.first?.keyPath == \Track.title && pane.shown.first?.title == TrackSort.sorted(store.tracks, using: [KeyPathComparator(\Track.title)]).first?.title)
            tv.sortDescriptors = [NSSortDescriptor(key: "title", ascending: false)]
            settle(); spin(0.3); settle()
            check("sortieren absteigend", pane.sortOrder.first?.order == .reverse && tv.numberOfRows == pane.shown.count)
            // Auswahl Tabelle -> Modell (Mehrfach), Modell -> Tabelle
            tv.selectRowIndexes(IndexSet([2, 5, 9]), byExtendingSelection: false)
            check("mehrfachauswahl", pane.selection == Set([2, 5, 9].map { pane.shown[$0].key }))
            // Doppelklick auf den Trenner: Spalte Titel auf den längsten Titel
            if let ti = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" }) {
                let c = tv.tableColumns[ti], before = c.width
                c.width = c.minWidth
                (tv.headerView as? TrackHeaderView)?.onFitColumn?(ti)
                let longest = pane.shown.map(\.title.utf16.count).max() ?? 0
                log("spalte titel: \(before) -> \(c.width) (min \(c.minWidth), längster titel \(longest) zeichen)")
                check("spalte auf längsten text", c.width > c.minWidth && c.width >= CGFloat(longest) * 5)
                c.width = before
            }
            pane.selection = [pane.shown[40].key]
            settle()
            check("auswahl aus dem modell", tv.selectedRowIndexes == IndexSet(integer: 40))
            // Browse-Encoder: Schritt +3 -> Auswahl und sichtbar
            browser.activePaneID = pane.id
            browser.moveSelection(by: 300, pane: 0)
            settle()
            check("encoder", tv.selectedRowIndexes == IndexSet(integer: 340) && tv.rows(in: tv.visibleRect).contains(340))
            // Return: Inline-Bearbeitung der gewählten Zeile
            win.makeFirstResponder(tv)
            if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                tv.keyDown(with: e)
            }
            settle()
            let editing = pane.inline
            check("return = inline", editing?.key == pane.shown[340].key && tv.subviews.contains { $0 is NSTableRowView && $0.subviews.contains { $0 is InlineFieldCell } })
            pane.inline = nil
            settle()
            // Suche (Hintergrund) und Quelle
            pane.search = "techno"
            settle(); spin(0.3); settle()
            check("suche", tv.numberOfRows == pane.shown.count && pane.shown.count < store.tracks.count && pane.shown.count == pane.rows(from: store, history: history, separators: mix.prefs.ui.tagSeparators).count)
            pane.search = ""
            pane.roles = [.basis]
            settle(); spin(0.3); settle()
            check("rolle", tv.numberOfRows == pane.shown.count && !pane.shown.isEmpty && pane.shown.allSatisfy {
                $0.comment2.localizedCaseInsensitiveContains("» BASIS") || Tags.split($0.comment2, separators: mix.prefs.ui.tagSeparators).contains("BASIS")
            })
            pane.roles = []
            // Matching (◆ PASST) und Sortierung „Harmonie“ (Kopf der Match-Spalte) mit festem Bezug 1m @ 128
            let ref = HarmonyRef(key: 21, bpm: 128)
            mix.harmonyFixed = ref
            pane.matching = true
            settle(); spin(0.3); settle()
            check("matching", tv.numberOfRows == pane.shown.count && pane.shown.count < store.tracks.count && !pane.shown.isEmpty
                  && pane.shown.allSatisfy { mix.prefs.ui.match.matches($0, ref) })
            pane.matching = false
            tv.sortDescriptors = [NSSortDescriptor(key: "harmony", ascending: true)]
            settle(); spin(0.3); settle()
            let ranks = pane.shown.map { mix.prefs.ui.match.rank($0, ref) }
            check("sortieren harmonie", pane.harmonySorted && tv.numberOfRows == store.tracks.count && zip(ranks, ranks.dropFirst()).allSatisfy { $0 <= $1 })
            tv.sortDescriptors = [NSSortDescriptor(key: "artist", ascending: true)]
            mix.harmonyFixed = nil
            settle(); spin(0.3); settle()
            func lists(_ n: PlaylistNode) -> [PlaylistNode] { (n.kind == .playlist ? [n] : []) + n.children.flatMap(lists) }
            if let big = lists(store.root).max(by: { $0.trackKeys.count < $1.trackKeys.count }) {
                pane.source = .node(big)
                settle(); spin(0.3); settle()
                check("quelle playlist", tv.numberOfRows == store.tracks(for: .node(big)).count)
                pane.source = .collection
                settle(); spin(0.3); settle()
                check("quelle collection", tv.numberOfRows == store.tracks.count)
            }
            // Spalten: ausblenden, verschieben, Breite -> Anordnung im Format der gespeicherten Spalten
            if let c = tv.tableColumns.first(where: { $0.identifier.rawValue == "label" }) { c.isHidden = true }
            tv.moveColumn(tv.column(withIdentifier: NSUserInterfaceItemIdentifier("bpm")), toColumn: 0)
            var st = ColumnLayout.State()
            for c in tv.tableColumns { st.order.append(c.identifier.rawValue); st.widths[c.identifier.rawValue] = c.width; if c.isHidden != TrackColumn.byID[c.identifier.rawValue]!.hidden { st.hidden[c.identifier.rawValue] = c.isHidden } }
            let back = ColumnLayout.decode(ColumnLayout.encode(st))
            // Kontextmenü einer Zeile (Rechtsklick auf Zeile 3, nicht in der Auswahl -> nur diese Zeile)
            let p3 = tv.convert(NSPoint(x: tv.rect(ofRow: 3).midX, y: tv.rect(ofRow: 3).midY), to: nil)
            if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p3, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
               let menu = tv.menu(for: e) {
                menu.delegate?.menuNeedsUpdate?(menu)
                let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
                log("kontextmenü zeile \(tv.clickedRow): " + titles.joined(separator: " · "))
                let prep = menu.items.first { $0.title == String(localized: "An Preparation anhängen") }
                if let prep, let a = prep.action { NSApp.sendAction(a, to: prep.target, from: prep) }
                check("kontextmenü", tv.clickedRow == 3 && titles.count >= 10 && store.preparation == [pane.shown[3].key])
                store.preparation = []
            }
            // Kopf-Menü: eine Zeile je Spalte (ohne Vorschau), Klick blendet ein/aus
            if let menu = tv.headerView?.menu {
                menu.delegate?.menuNeedsUpdate?(menu)
                let item = menu.items.first { $0.title == "Genre" }
                let before = tv.tableColumns.first { $0.identifier.rawValue == "genre" }?.isHidden
                if let item, let a = item.action { NSApp.sendAction(a, to: item.target, from: item) }
                // Spalten-Einträge bis zum Trenner, dahinter die Sortierung (Titel, je Spalte, zurücksetzen)
                let columns = menu.items.prefix { !$0.isSeparatorItem }.count
                let sortItems = menu.items.drop { !$0.isSeparatorItem }.dropFirst().count
                check("kopf-menü", columns == TrackColumn.all.count - 2 && sortItems == 3 && item?.state == .off && before == true
                      && tv.tableColumns.first { $0.identifier.rawValue == "genre" }?.isHidden == false)
            }
            check("spalten", back?.order.first == "bpm" && back?.hidden["label"] == true)
            twoLineChecks(tv, pane, h, settle, check, log)
            // Zoom: Zeilenhöhe und Breiten wachsen mit (Fenster wächst wie in der App mit)
            func width(_ id: String) -> CGFloat { tv.tableColumns.first { $0.identifier.rawValue == id }?.width ?? 0 }
            let w0 = width("artist"), b0 = width("bpm"), r0 = tv.rowHeight
            UIZoom.shared.factor = 1.5
            win.setContentSize(NSSize(width: 2100, height: 960))
            h.frame = NSRect(x: 0, y: 0, width: 2100, height: 960)
            settle()
            log(String(format: "zoom 1 -> 1.5: zeile %.1f -> %.1f, artist %.1f -> %.1f, bpm %.1f -> %.1f", r0, tv.rowHeight, w0, width("artist"), b0, width("bpm")))
            // flexible Spalten verteilt die Tabelle auf die Breite (gleichmäßig), feste und Mindestbreiten wachsen mit
            let artistMin = tv.tableColumns.first { $0.identifier.rawValue == "artist" }?.minWidth ?? 0
            check("zoom", tv.rowHeight > r0 * 1.2 && abs(width("bpm") - b0 * 1.5) < 1 && abs(artistMin - 120) < 1 && width("artist") >= artistMin)
            UIZoom.shared.factor = 1
            settle()
            win.contentView = nil
            win.close()
            log(ok ? "prüfungen OK" : "prüfungen FEHLER")
            exit(ok ? 0 : 1)
        }

        // Liste: Collection nach Artist, ab einer Stelle mit Kommentar 2 (Tags sichtbar)
        let rows = pane.rows(from: store, history: history, separators: mix.prefs.ui.tagSeparators)
        let first = rows.firstIndex { !$0.comment2.isEmpty && $0.bpm > 0 } ?? 0
        let modes: [(PreviewMode, String)] = [(.fullRow, "row"), (.column, "column"), (.behindTitle, "title"), (.off, "off")]
        let only = env["MIX741_SHOT_MODES"].map { Set($0.split(separator: ",").map(String.init)) }
        for (mode, name) in modes where only?.contains(name) ?? true {
            mix.prefs.ui.previewMode = mode
            let (h, win) = host(size: NSSize(width: Double(env["MIX741_SHOT_W"] ?? "") ?? 1400, height: 640))
            for _ in 0..<8 { h.layoutSubtreeIfNeeded(); spin(0.2) }
            guard let tv = table(h) else { log("keine tabelle"); exit(1) }
            if name == "row" || only != nil { describe(tv) }
            tv.scrollRowToVisible(min(rows.count - 1, first + 30))
            tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: first).minY))
            for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.3) }
            spin(1)   // Vorschau-Bilder im Hintergrund
            png(h, "table-\(name).png")
            // Auswahl (Zeile 3) + Inline-Bearbeitung (Titel, Zeile 5)
            if rows.count > first + 5 {
                pane.selection = [rows[first + 2].key]
                pane.inlineText = rows[first + 4].title
                pane.inline = InlineEdit(key: rows[first + 4].key, field: .title, serial: 1)
                for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.3) }
                png(h, "table-\(name)-edit.png")
                pane.inline = nil
                pane.selection = []
            }
            win.contentView = nil
            win.close()
        }
        // Live-Lesbarkeit (MIX741_SHOT_MODES=live): dieselbe Liste normal (before) und im Live-Modus (after), zwei gespielte
        // Tracks, eine Auswahl; PNG live-list-before.png / live-list-after.png
        if only?.contains("live") ?? false, rows.count > first + 6 {
            mix.prefs.ui.previewMode = .off
            pane.twoLine = nil
            pane.detailBar = nil
            history.setPlayed(history.played.union([rows[first + 1].key, rows[first + 3].key]))
            for (name, on) in [("before", false), ("after", true)] {
                mix.prefs.ui.liveList = on
                let (h, win) = host(size: NSSize(width: Double(env["MIX741_SHOT_W"] ?? "") ?? 1400, height: 640))
                for _ in 0..<8 { h.layoutSubtreeIfNeeded(); spin(0.2) }
                guard let tv = table(h) else { log("keine tabelle"); exit(1) }
                tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: first).minY))
                pane.selection = [rows[first + 2].key]
                for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.3) }
                spin(1)
                png(h, "live-list-\(name).png")
                log("live \(name): zeile \(tv.rowHeight) pt · spalten " + tv.tableColumns.filter { !$0.isHidden }.map { "\($0.identifier.rawValue) \(Int($0.width))" }.joined(separator: ", "))
                pane.selection = []
                win.contentView = nil
                win.close()
            }
            mix.prefs.ui.liveList = false
        }
        // Zeilen zweizeilig (Sammelspalte), Detailleiste, Auswahl (drei Zeilen gewählt, eine davon gespielt-gedimmt):
        // table-<name>.png; MIX741_SHOT_MODES=two,two-row,two-detail,one-detail,select
        let looks: [(String, PreviewMode, Bool, Bool)] = [("two", .off, true, false), ("two-row", .fullRow, true, false),
                                                          ("two-detail", .off, true, true), ("one-detail", .off, false, true), ("select", .off, false, false)]
        for (name, mode, two, detail) in looks where only?.contains(name) ?? false || only == nil {
            mix.prefs.ui.previewMode = mode
            pane.twoLine = two
            pane.detailBar = detail
            let width = Double(env["MIX741_SHOT_W"] ?? "") ?? 1400
            let (h, win) = host(size: NSSize(width: width, height: 640))
            for _ in 0..<8 { h.layoutSubtreeIfNeeded(); spin(0.2) }
            guard let tv = table(h) else { log("keine tabelle"); exit(1) }
            tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: first).minY))
            if rows.count > first + 6 {
                pane.selection = [rows[first + 1].key, rows[first + 2].key, rows[first + 4].key]
                history.setPlayed(history.played.union([rows[first + 2].key, rows[first + 3].key]))
            }
            for _ in 0..<4 { h.layoutSubtreeIfNeeded(); spin(0.3) }
            spin(1)
            png(h, "table-\(name).png")
            log("\(name): zeile \(tv.rowHeight) pt · spalten " + tv.tableColumns.filter { !$0.isHidden }.map { "\($0.identifier.rawValue) \(Int($0.width))" }.joined(separator: ", "))
            pane.selection = []
            win.contentView = nil
            win.close()
        }
        pane.twoLine = nil
        pane.detailBar = nil
        // Harmonie: Bezug fest gesetzt (MIX741_SHOT_KEY=<open key>@<bpm>, sonst Key und Tempo einer Zeile der Liste),
        // Key-Farben nach Artist, nach Master-Wechsel, nach „Harmonie“ sortiert, Matching an
        if only?.contains("harmony") ?? true, rows.count > first + 5 {
            let spec = env["MIX741_SHOT_KEY"]?.split(separator: "@")
            let pick = rows[(first + 3)...].first { $0.harmonyCode != nil && $0.bpm > 0 } ?? rows[first]
            let ref = HarmonyRef(key: spec.flatMap { Harmony.code(text: String($0[0])) } ?? pick.harmonyCode,
                                 bpm: spec.flatMap { $0.count > 1 ? Double($0[1]) : nil } ?? (pick.bpm * 10).rounded() / 10)
            mix.prefs.ui.previewMode = .off
            mix.harmonyFixed = ref
            log("bezug \(ref.key.map(Track.openKey(code:)) ?? "-") \(ref.bpm) bpm · regel \(mix.prefs.ui.match)")
            let (h, win) = host(size: NSSize(width: Double(env["MIX741_SHOT_W"] ?? "") ?? 1400, height: 640))
            func settle() { for _ in 0..<6 { h.layoutSubtreeIfNeeded(); spin(0.2) } }
            settle()
            guard let tv = table(h) else { log("keine tabelle"); exit(1) }
            // Stelle mit Artist, Key und Tempo in 25 Zeilen am Stück (verschiedene Keys sichtbar)
            let start = rows.indices.first { i in i + 25 < rows.count && rows[i..<(i + 25)].allSatisfy { !$0.artist.isEmpty && $0.harmonyCode != nil && $0.bpm > 0 } } ?? first
            tv.scroll(NSPoint(x: 0, y: tv.rect(ofRow: start).minY))
            settle()
            png(h, "table-harmony-keys.png")
            // Master-Wechsel (Key eine Quinte höher): nur Key-/Match-Zellen neu, kein Neuaufbau der Liste
            let gen = pane.tableGeneration, count = tv.numberOfRows
            mix.harmonyFixed = HarmonyRef(key: ref.key.map { Harmony.shifted($0, by: 7) }, bpm: ref.bpm)
            settle()
            png(h, "table-harmony-keys-shift.png")
            log("master-wechsel: neuaufbau \(pane.tableGeneration - gen), zeilen \(count) -> \(tv.numberOfRows)")
            mix.harmonyFixed = ref
            pane.sortOrder = [KeyPathComparator(\Track.harmonySort)]
            settle(); spin(0.5); settle()
            tv.scroll(.zero)
            settle()
            log("harmonie sortiert: " + pane.shown.prefix(8).map { "\($0.openKey) \(String(format: "%.1f", $0.bpm))" }.joined(separator: " · "))
            png(h, "table-harmony-sorted.png")
            pane.sortOrder = [KeyPathComparator(\Track.artist)]
            pane.matching = true
            settle(); spin(0.5); settle()
            let ok = pane.shown.allSatisfy { mix.prefs.ui.match.matches($0, ref) }
            log("matching: \(pane.shown.count) von \(rows.count) tracks, alle passend: \(ok)")
            png(h, "table-harmony-matching.png")
            pane.matching = false
            win.contentView = nil
            win.close()
            if !ok { exit(1) }
        }
        exit(0)
    }
}
