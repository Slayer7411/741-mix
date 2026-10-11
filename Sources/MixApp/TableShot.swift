import AppKit
import QuartzCore
import SwiftUI
import MixCore

/// Selbsttest-Bilder der Track-Tabelle (MIX741_SELFTEST=1 MIX741_SHOT=table:<ordner>), offscreen, ohne Audio:
/// Browser-Bereich je Vorschau-Modus als PNG (mit Auswahl und Inline-Bearbeitung), Kennzahlen der Tabelle (Zeilenhöhe,
/// Abstände, Kopf, Spalten) ins Protokoll. MIX741_SHOT_COLUMNS=<json>: Spalten-Anordnung (Format von `columns.*`),
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
        let d = UserDefaults.standard
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

        func host(size: NSSize) -> (NSHostingView<AnyView>, NSWindow) {
            let view = AnyView(BrowserPane(model: pane)
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
                    guard let v = tv.view(atColumn: i, row: 0, makeIfNecessary: false) else { continue }
                    log("  zelle \(c.identifier.rawValue): \(type(of: v)) \(NSStringFromRect(v.frame))")
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
        exit(0)
    }
}
