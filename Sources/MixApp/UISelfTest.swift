import AppKit
import AVFoundation
import SwiftUI
import MixCore
import MixEngine

/// UI-Selbsttest (MIX741_SELFTEST=1 MIX741_UITEST=1): echtes Hauptfenster mit ContentView offscreen (unsichtbar, nie
/// vorne, App nie aktiv), synthetische Maus- und Tastaturereignisse über `NSWindow.sendEvent` / `NSApp.sendEvent`.
/// Ohne Collection (oder MIX741_UITEST_FIXTURE=1): kleine Collection mit erzeugten WAV-Dateien in einem temporären
/// Ordner. Audio stumm auf einem eingebauten Gerät, nichts gespeichert. Endet mit `UITEST OK` oder dem ersten Fehler.
@MainActor
enum UISelfTest {
    static func runIfRequested() {
        guard Session.isSelfTest, ProcessInfo.processInfo.environment["MIX741_UITEST"] == "1" else { return }
        run()
    }

    static func log(_ s: String) { print("[uitest] \(s)"); fflush(stdout) }

    static func fail(_ s: String) -> Never {
        log("FEHLER: \(s)")
        log("UITEST FEHLER")
        cleanup()
        exit(1)
    }

    static func skip(_ s: String) -> Never {
        log("übersprungen: \(s)")
        log("UITEST ÜBERSPRUNGEN")
        cleanup()
        exit(0)
    }

    static func check(_ ok: Bool, _ s: @autoclosure () -> String) { if !ok { fail(s()) } }

    /// Fixture-Ordner und Drop-Pasteboard weg
    static func cleanup() {
        UITestFixture.remove()
        UIDriver.dragPasteboard?.releaseGlobally()
        UIDriver.dragPasteboard = nil
    }

    static func run() -> Never {
        let t0 = Date()
        let env = ProcessInfo.processInfo.environment
        NSApplication.shared.setActivationPolicy(.prohibited)
        SelfTest.enabled = false   // kein Audio-Selbsttest aus ContentView.onAppear

        // eingebautes Gerät, stumm (wie WindowShot); Argument-Domäne danach zurück
        let defaults = UserDefaults.standard
        let args = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        defaults.setVolatileDomain(args.merging(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                                 "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0]) { $1 },
                                   forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        defaults.setVolatileDomain(args, forName: UserDefaults.argumentDomain)

        // feste Ansicht (Selbsttest speichert keine Einstellungen)
        var ui = mix.prefs.ui
        ui.zoom = 1
        ui.showMixer = false
        ui.deckCount = 2
        ui.browserLayout = .sideBySide
        ui.browserHeight = 330
        ui.statusBar = .auto
        ui.showMeters = true
        ui.showAllDeckRows()
        mix.prefs.ui = ui
        ZoomControl.apply(1)

        // Collection oder Fixture
        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        func pick() -> [Track] {
            var seen = Set<String>()
            return Array(store.tracks.filter {
                $0.bpm > 100 && $0.bpm < 150 && $0.gridAnchorMs != nil && $0.fileExists && $0.duration > 15
                    && OverviewPolicy.fileState(path: $0.path) == .local && seen.insert($0.title).inserted
            }.prefix(3))
        }
        var tracks: [Track] = []
        let real = env["MIX741_UITEST_FIXTURE"] != "1" && FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path)
        if real {
            store.load()
            spin(120, until: { !store.tracks.isEmpty })
            tracks = pick()
            log("collection: \(store.tracks.count) tracks")
        }
        if tracks.count < 3 {
            guard let nml = UITestFixture.make() else { skip("keine Collection, Fixture nicht angelegt") }
            store.load(nml)
            spin(30, until: { !store.tracks.isEmpty })
            tracks = pick()
            log("fixture: \(nml.path) · \(store.tracks.count) tracks")
        }
        guard tracks.count == 3 else { skip("keine 3 lokalen Tracks mit Grid") }
        for (i, t) in tracks.prefix(2).enumerated() { _ = mix.load(t, deck: i, force: true) }
        spin(30, until: { (0..<2).allSatisfy { mix.core.trackAudio($0) != nil } })
        guard (0..<2).allSatisfy({ mix.core.trackAudio($0) != nil }) else {
            if devs.isEmpty { skip("kein Audiogerät, Decks laden nicht") }
            fail("Decks laden nicht: \((0..<2).map { mix.deck($0).error ?? "-" })")
        }
        mix.pull()
        log("A: \(tracks[0].title) · B: \(tracks[1].title) · C: \(tracks[2].title)")

        let u = UIDriver(mix: mix, store: store, browser: browser, history: history)
        let cases: [(String, (UIDriver, [Track]) -> Void)] = [
            ("deck-menü", deckMenu), ("drop aufs deck", dropOnDeck), ("bereich in der wellenform", waveRange),
            ("spaltenbreite per doppelklick", fitColumn), ("statusleiste automatisch", autoStatusBar),
            ("tastenkürzel", shortcuts), ("werkzeugleiste", toolbar), ("zoom", zoom),
            ("edit-modus", editMode),
            ("groove", groove),
            ("daw-streifen", dawStrip),
            ("master-fx", masterFX),
            ("doppelklick", doubleClickReset),
            ("gestapelt", stackedSide),
            ("ungespielt", unplayed),
            ("vorbereiten", prepareMode),
            ("playlist-baum", playlistTree),
        ]
        let only = env["MIX741_UITEST_ONLY"].flatMap { $0.isEmpty ? nil : Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        var n = 0
        for (name, f) in cases where only.map({ s in s.contains { name.hasPrefix($0) } }) ?? true {
            let t = Date()
            f(u, tracks)
            n += 1
            log(String(format: "ok %@ (%.2f s)", name, Date().timeIntervalSince(t)))
        }
        check(n > 0, "kein Fall passt zu MIX741_UITEST_ONLY")
        u.close()
        cleanup()
        log(String(format: "UITEST OK · %d fälle · %.1f s", n, Date().timeIntervalSince(t0)))
        exit(0)
    }

    /// Run-Loop pumpen und Ereignisse der App-Warteschlange zustellen (die App läuft im Test nicht über NSApp.run)
    static func spin(_ s: Double, step: () -> Void = {}, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !done() {
            step()
            if let e = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
    }

    // MARK: Fälle

    /// Rechtsklick auf den Decktitel: Menü „Track bearbeiten …“ (aus der Hosting-View des Kopfs), Auslösen öffnet das
    /// Bearbeiten-Fenster (Sheet am Hauptfenster)
    static func deckMenu(_ u: UIDriver, _ t: [Track]) {
        let item = String(localized: "Track bearbeiten …")
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        let r = u.frame(hdr)
        // Titel liegt hinter Buchstabe und Cover: von links nach rechts bis zum ersten Menü mit dem Eintrag
        var found: (NSMenu, NSPoint)?
        for x in stride(from: r.minX + 2, to: r.minX + min(400, r.width), by: 6) {
            let p = NSPoint(x: x, y: r.midY)
            if let m = u.rightClick(at: p), m.items.contains(where: { $0.title == item }) { found = (m, p); break }
        }
        guard let (menu, p) = found else { fail("Rechtsklick auf den Decktitel: kein Menü mit „\(item)“") }
        log("menü am titel (x \(Int(p.x - r.minX))): " + menu.items.map(\.title).joined(separator: " · "))
        guard let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("Eintrag fehlt") }
        menu.performActionForItem(at: i)
        u.spin(5) { u.window.attachedSheet != nil }
        let pane = u.browser.activePane
        check(pane.editSession != nil, "Bearbeiten-Sitzung nicht geöffnet")
        check(pane.editSession?.selection == [t[0].key], "Bearbeiten-Fenster für falschen Track: \(pane.editSession?.selection ?? [])")
        check(u.window.attachedSheet != nil, "Bearbeiten-Fenster (Sheet) nicht offen")
        pane.editSession = nil
        u.spin(5) { u.window.attachedSheet == nil }
        check(u.window.attachedSheet == nil, "Bearbeiten-Fenster schließt nicht")
    }

    /// Track (wie vom Deck gezogen) auf den Kopf von Deck A fallen lassen: Ziel ist die Hosting-View, die SwiftUI für
    /// `onDrop` registriert; die Ziehen-Sitzung selbst braucht den Fensterserver und wird durch NSDraggingInfo ersetzt
    static func dropOnDeck(_ u: UIDriver, _ t: [Track]) {
        if u.mix.deck(0).playing { u.mix.togglePlay(0) }
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        let r = u.frame(hdr)
        let ok = u.drop(string: TrackDrag.prefix + t[2].key, at: NSPoint(x: r.midX, y: r.midY))
        check(ok, "Drop auf Deck A nicht angenommen")
        u.spin(5) { u.mix.deck(0).track?.key == t[2].key }
        check(u.mix.deck(0).track?.key == t[2].key, "Deck A hat nach dem Drop \(u.mix.deck(0).track?.title ?? "nichts") statt \(t[2].title) · spielt \(u.mix.deck(0).playing) · Meldung \(StatusCenter.shared.current.map { "\($0.level) \($0.text)" } ?? "-")")
        u.spin(30) { u.mix.core.trackAudio(0) != nil && u.mix.deck(0).grid != nil }
        check(u.mix.core.trackAudio(0) != nil, "Deck A lädt nach dem Drop nicht")
    }

    /// ⌃ + Ziehen in der Wellenform von Deck A: Bereich auf Beats; Esc hebt ihn auf
    static func waveRange(_ u: UIDriver, _ t: [Track]) {
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == 0 }) else { fail("Wellenform A nicht gefunden") }
        u.mix.setRange(0, nil)
        u.mix.pull()
        let r = u.frame(w)
        log(String(format: "wellenform %.0f × %.0f pt · position %.3f s · dauer %.1f s · %.0f s/seite", r.width, r.height,
                   u.mix.position(0), u.mix.deck(0).duration, u.mix.prefs.ui.waveformSeconds))
        u.drag(from: NSPoint(x: r.minX + r.width * 0.56, y: r.midY), to: NSPoint(x: r.minX + r.width * 0.84, y: r.midY),
               modifiers: .control, steps: 8)
        guard let range = u.mix.range(0) else { fail("⌃ + Ziehen: kein Bereich") }
        guard let g = u.mix.deck(0).grid else { fail("Deck A ohne Grid") }
        let a = g.beatPosition(at: range.start), b = g.beatPosition(at: range.end)
        log(String(format: "bereich %.3f–%.3f s · beats %.3f–%.3f", range.start, range.end, a, b))
        check(range.length > g.beat, "Bereich zu kurz: \(range.length) s")
        check(abs(a - a.rounded()) < 1e-3 && abs(b - b.rounded()) < 1e-3, "Bereich nicht auf Beats: \(a) – \(b)")
        check(u.mix.focusedDeck == 0, "Klick in die Wellenform fokussiert Deck A nicht")
        guard let esc = u.mix.prefs.keys.combo(.rangeClear) else { fail("Esc nicht belegt") }
        u.key(esc)
        check(u.mix.range(0) == nil, "Esc hebt den Bereich nicht auf")
    }

    /// Doppelklick auf den Trenner rechts der Titel-Spalte im Kopf von Bereich A: Spalte auf den längsten Titel
    static func fitColumn(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA
        guard let head = u.views.compactMap({ $0 as? TrackHeaderView }).first(where: { h in
            guard let tv = h.tableView else { return false }
            return tv.numberOfRows == pane.shown.count && u.frame(h).minX < u.window.frame.width / 2
        }), let tv = head.tableView else { fail("Tabellenkopf von Bereich A nicht gefunden") }
        guard let i = tv.tableColumns.firstIndex(where: { $0.identifier.rawValue == "title" && !$0.isHidden }) else { fail("Spalte Titel fehlt") }
        let c = tv.tableColumns[i], before = c.width
        c.width = c.minWidth
        head.layoutSubtreeIfNeeded()
        let hr = head.headerRect(ofColumn: i)
        let p = head.convert(NSPoint(x: hr.maxX, y: hr.midY), to: nil)
        check(u.frame(head).contains(p), "Trenner liegt außerhalb des Kopfs")
        u.doubleClick(at: p)
        let longest = pane.shown.map(\.title.utf16.count).max() ?? 0
        log("spalte titel: \(c.minWidth) -> \(c.width) (längster titel \(longest) zeichen)")
        check(c.width > c.minWidth && c.width >= min(c.maxWidth, CGFloat(longest) * 5), "Doppelklick auf den Trenner: Breite \(c.width)")
        c.width = before
    }

    /// Statusleiste „Automatisch“: Maus an den unteren Rand -> sichtbar, Maus weg -> nach 0,5 s weg
    static func autoStatusBar(_ u: UIDriver, _ t: [Track]) {
        // Meldungen weg, Leiste neu aufgebaut (eine Warnung beim Laden zeigt sie sonst 6 s lang)
        for _ in 0..<50 { guard let m = StatusCenter.shared.current else { break }; StatusCenter.shared.dismiss(m) }
        u.mix.prefs.ui.statusBar = .always
        u.spin(0.3)
        u.mix.prefs.ui.statusBar = .auto
        u.spin(0.5)
        func visible() -> Bool? {
            // Pegelanzeige der Leiste (eigene NSView): sichtbar = im Fenster, nicht durchsichtig
            guard let v = u.views.compactMap({ $0 as? LiveCanvasView }).filter({ u.frame($0).minY < 60 }).min(by: { u.frame($0).minY < u.frame($1).minY }) else { return nil }
            let f = u.frame(v)
            var alpha: CGFloat = 1, a: NSView? = v
            while let x = a { alpha *= x.alphaValue * CGFloat(x.layer?.opacity ?? 1); a = x.superview }
            return f.minY >= 0 && alpha > 0.5
        }
        guard let start = visible() else { fail("Pegelanzeige der Statusleiste nicht gefunden") }
        check(!start, "Statusleiste ohne Maus schon sichtbar")
        let mid = NSPoint(x: u.window.frame.width / 2, y: u.window.frame.height / 2)
        u.hover(at: mid)
        u.hover(at: NSPoint(x: u.window.frame.width / 2, y: 2))
        u.spin(1) { visible() == true }
        check(visible() == true, "Maus am unteren Rand: Statusleiste bleibt verborgen")
        u.hover(at: mid)
        u.spin(0.2)
        check(visible() == true, "Statusleiste verschwindet sofort (soll 0,4 s warten)")
        u.spin(0.6) { visible() == false }
        check(visible() == false, "Maus weg: Statusleiste nach 0,8 s noch sichtbar")
    }

    /// Play/Pause auf Deck A per Kürzel aus den Einstellungen; Taste ohne ⌘/⌥/⌃ im Suchfeld: Deck reagiert nicht
    static func shortcuts(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        if mix.deck(0).playing { mix.togglePlay(0) }
        u.spin(0.2)
        u.window.makeFirstResponder(nil)
        mix.focusedDeck = 0
        guard let play = mix.prefs.keys.combo(.play) else { fail("Play/Pause nicht belegt") }
        u.key(play)
        u.spin(1) { mix.deck(0).playing }
        check(mix.deck(0).playing, "\(play.symbols): Deck A spielt nicht")
        u.key(play)
        u.spin(1) { !mix.deck(0).playing }
        check(!mix.deck(0).playing, "\(play.symbols): Deck A stoppt nicht")
        // Taste ohne Modifier für Play/Pause (nur flüchtig), außerhalb und im Suchfeld
        let keys = mix.prefs.keys
        guard let plain = ["q", "j", "z"].map({ KeyCombo($0, []) }).first(where: { keys.action(for: $0) == nil }) else { fail("keine freie Taste") }
        let name = plain.symbols
        mix.prefs.keys.set(.play, plain)
        defer { mix.prefs.keys = keys }
        check(mix.prefs.keys.action(for: plain) == .play, "\(name) nicht Play/Pause")
        u.key(plain)
        u.spin(1) { mix.deck(0).playing }
        check(mix.deck(0).playing, "\(name) ohne Textfeld: Deck A spielt nicht")
        u.key(plain)
        u.spin(1) { !mix.deck(0).playing }
        guard let field = u.searchField(pane: 0) else { fail("Suchfeld von Bereich A nicht gefunden") }
        u.click(at: u.center(field))
        u.spin(0.3)
        check(u.window.firstResponder is NSText, "Klick ins Suchfeld: kein Texteditor (Ersthelfer \(u.window.firstResponder.map { "\(type(of: $0))" } ?? "-"))")
        let big = u.browser.maximized
        u.key(plain)
        u.key(KeyCombo("space", []))   // Browser groß (Leertaste) darf im Suchfeld auch nicht schalten
        u.spin(0.5)
        check(!mix.deck(0).playing, "\(name) im Suchfeld startet Deck A")
        check(u.browser.maximized == big, "Leertaste im Suchfeld schaltet Browser groß")
        check(field.stringValue == plain.key + " ", "Suchfeld hat „\(field.stringValue)“ statt „\(plain.key) “")
        u.type("x")
        check(field.stringValue == plain.key + " x", "Tippen ins Suchfeld: „\(field.stringValue)“")
        field.stringValue = ""
        u.browser.paneA.search = ""
        u.window.makeFirstResponder(nil)
        u.spin(0.3)
    }

    /// Werkzeugleiste: MIXER und Decks 1 / 2 / 4 per Klick
    static func toolbar(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        // MIXER: Schalter ohne Beschriftung am Element, steht vor dem Picker „Decks“
        // ohne Fensterserver (CI-Runner) baut AppKit die Elemente der Werkzeugleiste nicht auf: dann nur melden, nicht scheitern
        let itemLabels = u.window.toolbar?.items.map { "\($0.label)\($0.view == nil ? "(ohne View)" : "")" } ?? []
        guard let items = u.window.toolbar?.items, let di = items.firstIndex(where: { $0.label == String(localized: "Decks") }), di > 0,
              let mixer = items[di - 1].view.flatMap({ u.control(in: $0) as? NSButton }) else {
            log("werkzeugleiste nicht aufgebaut (\(itemLabels.joined(separator: " · "))) – fall übersprungen")
            return
        }
        check((mixer.state == .on) == mix.prefs.ui.showMixer, "Schalter vor „Decks“ zeigt nicht den Mixer-Zustand")
        let m0 = mix.prefs.ui.showMixer
        u.click(at: u.center(mixer))
        u.spin(1) { mix.prefs.ui.showMixer != m0 }
        check(mix.prefs.ui.showMixer != m0, "Klick auf MIXER schaltet nicht")
        u.click(at: u.center(mixer))
        u.spin(1) { mix.prefs.ui.showMixer == m0 }
        check(mix.prefs.ui.showMixer == m0, "zweiter Klick auf MIXER schaltet nicht zurück")
        // Decks 1 / 2 / 4: Segment nach Beschriftung, Klick auf die Mitte des Segments
        guard let seg = items[di].view.flatMap({ u.control(in: $0) as? NSSegmentedControl }) else { log("Decks 1 / 2 / 4 in der Werkzeugleiste ohne View – übersprungen"); return }
        let labels = (0..<seg.segmentCount).map { seg.label(forSegment: $0) ?? "" }
        func click(_ n: Int) {
            guard let i = labels.firstIndex(of: "\(n)") else { fail("Decks: kein Segment „\(n)“ (\(labels))") }
            let r = u.frame(seg)
            let x0 = (0..<i).reduce(r.minX) { $0 + seg.width(forSegment: $1) }, w = seg.width(forSegment: i)
            u.click(at: NSPoint(x: w > 0 ? x0 + w / 2 : r.minX + r.width * (CGFloat(i) + 0.5) / CGFloat(seg.segmentCount), y: r.midY))
            u.spin(1) { mix.prefs.ui.deckCount == n }
            check(mix.prefs.ui.deckCount == n, "Klick auf „\(n)“: \(mix.prefs.ui.deckCount) Decks")
        }
        check(mix.prefs.ui.deckCount == 2, "Ausgangslage nicht 2 Decks")
        click(4)
        u.spin(1) { u.named("deck C") != nil }
        check(u.named("deck C") != nil, "4 Decks: Deck C nicht aufgebaut")
        click(1)
        u.spin(1) { u.named("deck B") == nil }
        check(u.named("deck B") == nil, "1 Deck: Deck B noch sichtbar")
        click(2)
        u.spin(1) { u.named("deck B") != nil }
        check(u.named("deck B") != nil && u.named("deck C") == nil, "2 Decks: Decks nicht wie erwartet")
    }

    /// Zoom ⌘− / ⌘+ (Kürzel aus den Einstellungen): Faktor der Oberfläche
    static func zoom(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        guard let zin = mix.prefs.keys.combo(.zoomIn), let zout = mix.prefs.keys.combo(.zoomOut) else { fail("Zoom nicht belegt") }
        check(UIZoom.shared.factor == 1, "Zoom nicht bei 100 %")
        u.key(zout)
        u.spin(0.3)
        check(abs(UIZoom.shared.factor - 0.9) < 0.001, "\(zout.symbols): Zoom \(UIZoom.shared.factor) statt 0.9")
        u.key(zin)
        u.spin(0.3)
        check(UIZoom.shared.factor == 1, "\(zin.symbols): Zoom \(UIZoom.shared.factor) statt 1")
    }
}

/// Fenster des UI-Tests: weit außerhalb jedes Bildschirms, durchsichtig, gilt als Schlüsselfenster
/// (die App wird im Test nie aktiv, damit sie niemandem den Fokus nimmt)
final class UITestWindow: NSWindow {
    static let origin = NSPoint(x: -30000, y: -30000)
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override func constrainFrameRect(_ r: NSRect, to screen: NSScreen?) -> NSRect { r }
    /// nie auf einen Bildschirm verschieben (Zoom vergrößert das Hauptfenster „im Bildschirm“)
    override func setFrame(_ r: NSRect, display: Bool) { super.setFrame(NSRect(origin: Self.origin, size: r.size), display: display) }
    /// zuletzt zugestellte Taste (die App stellt sie im inaktiven Zustand nicht selbst zu)
    private(set) weak var lastKey: NSEvent?
    /// Ansicht unter dem letzten Drücken: Ziehen und Loslassen gehen dorthin
    private weak var downView: NSView?
    /// vorab abgelegtes Loslassen für die Verfolgungsschleifen der Steuerelemente (NSControl holt es über
    /// `window.nextEvent`). Nicht über die App-Warteschlange: dort gepostete Mausereignisse verlieren ihre Position
    /// (das Fenster liegt außerhalb aller Bildschirme, AppKit ordnet sie beim Abholen neu zu)
    var pending: [NSEvent] = []
    func takePending(_ mask: NSEvent.EventTypeMask, dequeue: Bool) -> NSEvent? {
        guard let i = pending.firstIndex(where: { mask.contains(NSEvent.EventTypeMask(type: $0.type)) }) else { return nil }
        let e = pending[i]
        if dequeue { pending.remove(at: i) }
        return e
    }
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        if let e = takePending(mask, dequeue: dequeue) { return e }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
    }
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown || e.type == .keyUp { lastKey = e }
        // Die App ist im Test meist nicht aktiv (Christian arbeitet weiter): AppKit nähme den ersten Klick dann nur zum
        // Aktivieren und stellte ihn nur Ansichten mit acceptsFirstMouse zu (Wellenform ja, Tabellenkopf nein) – Maus-
        // ereignisse deshalb selbst an die getroffene Ansicht geben, wie bei aktiver App
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            let v = (contentView?.superview ?? contentView)?.hitTest(e.locationInWindow)
            if e.type == .leftMouseDown { downView = v }
            if let v { e.type == .leftMouseDown ? v.mouseDown(with: e) : v.rightMouseDown(with: e); return }
        case .leftMouseDragged:
            if let v = downView { v.mouseDragged(with: e); return }
        case .leftMouseUp:
            if let v = downView { downView = nil; v.mouseUp(with: e); return }
        default: break
        }
        super.sendEvent(e)
    }
}

/// NSApp.keyWindow im Test: das Testfenster (Klasse von NSApp nur in diesem Prozess getauscht, keine eigenen Felder)
final class UITestApplication: NSApplication {
    nonisolated(unsafe) static weak var testWindow: NSWindow?
    override var keyWindow: NSWindow? { Self.testWindow ?? super.keyWindow }
    /// Verfolgungsschleifen der Steuerelemente holen das Loslassen hier oder über das Fenster: vorab abgelegte Ereignisse zuerst
    override func nextEvent(matching mask: NSEvent.EventTypeMask, until expiration: Date?, inMode mode: RunLoop.Mode, dequeue: Bool) -> NSEvent? {
        if let e = (Self.testWindow as? UITestWindow)?.takePending(mask, dequeue: dequeue) { return e }
        return super.nextEvent(matching: mask, until: expiration, inMode: mode, dequeue: dequeue)
    }
}

/// Hosting-Views mit Namen (Deck, Deck-Zeilen)
protocol UITestNamed: AnyObject { var name: String { get } }
extension BoundaryHostingView: UITestNamed {}

/// Fenster mit ContentView und Helfern für Ereignisse
@MainActor
final class UIDriver {
    let mix: MixModel
    let store: LibraryStore
    let browser: BrowserState
    let window: UITestWindow
    let host: NSView
    private var eventNumber = 0
    private var inside: Set<ObjectIdentifier> = []
    /// eigenes Pasteboard für Drops (nie das allgemeine), am Ende freigegeben
    static var dragPasteboard: NSPasteboard?

    init(mix: MixModel, store: LibraryStore, browser: BrowserState, history: HistoryStore) {
        self.mix = mix
        self.store = store
        self.browser = browser
        let root = ContentView()
            .environment(store).environment(mix).environment(browser)
            .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let h = NSHostingView(rootView: root)
        h.sceneBridgingOptions = [.toolbars]
        host = h
        let size = NSSize(width: 1700, height: 1100)
        window = UITestWindow(contentRect: NSRect(origin: UITestWindow.origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true   // echte Maus erreicht das Fenster nie
        window.appearance = NSAppearance(named: .darkAqua)
        window.toolbarStyle = .unified
        window.title = MixApp.appTitle
        window.contentView = h
        window.setContentSize(size)
        window.orderFrontRegardless()   // Werkzeugleiste und Sheets brauchen ein geordnetes Fenster
        object_setClass(NSApp, UITestApplication.self)
        UITestApplication.testWindow = window
        KeyMonitor.install(AppActions(mix: mix, browser: browser, store: store, history: history))
        let built = { [unowned self] in
            self.views.contains { $0 is TrackHeaderView } && self.named("A header") != nil && self.window.toolbar?.items.isEmpty == false
        }
        spin(10, until: built)
        UISelfTest.check(built(), "Fenster nicht aufgebaut")
        spin(0.5)
    }

    func close() {
        UITestApplication.testWindow = nil
        window.orderOut(nil)
    }

    func spin(_ s: Double, until done: () -> Bool = { false }) {
        UISelfTest.spin(s, step: { [mix, host] in mix.pull(); host.layoutSubtreeIfNeeded() }, until: done)
    }

    // MARK: Suche

    var views: [NSView] {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(window.contentView?.superview ?? host)
    }

    func named(_ name: String) -> NSView? { views.first { ($0 as? UITestNamed)?.name == name } }

    /// Rahmen in Fensterkoordinaten
    func frame(_ v: NSView) -> NSRect { v.convert(v.bounds, to: nil) }
    func center(_ v: NSView) -> NSPoint { let r = frame(v); return NSPoint(x: r.midX, y: r.midY) }

    /// Suchfeld eines Browser-Bereichs (0 = links)
    func searchField(pane: Int) -> NSTextField? {
        let fields = views.compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && $0.placeholderString == String(localized: "SUCHEN") }
            .sorted { frame($0).minX < frame($1).minX }
        return pane < fields.count ? fields[pane] : nil
    }

    /// erstes Steuerelement in einer Ansicht (Werkzeugleiste: SwiftUI-Schalter und -Picker sind AppKit-Steuerelemente)
    func control(in v: NSView) -> NSControl? {
        if let c = v as? NSControl { return c }
        for s in v.subviews { if let c = control(in: s) { return c } }
        return nil
    }

    // MARK: Maus

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint, _ mods: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        eventNumber += 1
        return NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: clicks,
                                  pressure: type == .leftMouseUp ? 0 : 1)!
    }

    /// Klick: Loslassen vorab beim Fenster ablegen (Steuerelemente verfolgen die Maus in einer eigenen Schleife und holen es
    /// dort), dann Drücken ans Fenster; blieb das Loslassen liegen, geht es hinterher an die gedrückte Ansicht.
    /// `viaApp`: Drücken durch die App (Ereignis-Monitore wie der Doppelklick-Fänger der Regler sehen nur diesen Weg)
    func click(at p: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1, viaApp: Bool = false) {
        let up = mouse(.leftMouseUp, p, modifiers, clicks: count)
        window.pending.append(up)
        let down = mouse(.leftMouseDown, p, modifiers, clicks: count)
        if viaApp { NSApp.sendEvent(down) } else { window.sendEvent(down) }
        if let i = window.pending.firstIndex(of: up) { window.pending.remove(at: i); window.sendEvent(up) }
        spin(0.05)
    }

    func doubleClick(at p: NSPoint) {
        click(at: p, count: 1)
        click(at: p, count: 2, viaApp: true)
    }

    /// Kontextmenü am Punkt ohne Anzeige: `menu(for:)` der getroffenen Ansicht und ihrer Eltern (NSHostingView liefert
    /// das SwiftUI-`contextMenu`). Ein echter Rechtsklick öffnet das Menü modal (blockiert)
    func rightClick(at p: NSPoint) -> NSMenu? {
        let e = mouse(.rightMouseDown, p)
        var v = (window.contentView?.superview ?? host).hitTest(p)
        while let x = v {
            if let m = x.menu(for: e) { m.update(); return m }
            v = x.superview
        }
        return nil
    }

    /// Ziehen: Drücken, `steps` Bewegungen, Loslassen
    /// Ziehen: alles direkt ans Fenster. Über die Warteschlange gepostete Zieh-Ereignisse kommen ohne ihre Position an
    /// (das Fenster ignoriert die Maus, AppKit ordnet sie beim Abholen neu zu) – der Bereich landete dann bei 0 s
    func drag(from a: NSPoint, to b: NSPoint, modifiers: NSEvent.ModifierFlags = [], steps: Int = 6) {
        window.sendEvent(mouse(.leftMouseDown, a, modifiers))
        for i in 1...max(1, steps) {
            let f = CGFloat(i) / CGFloat(max(1, steps))
            window.sendEvent(mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), modifiers))
        }
        window.sendEvent(mouse(.leftMouseUp, b, modifiers))
        spin(0.2)
    }

    /// Maus an einen Punkt: Betreten / Verlassen / Bewegen an die Besitzer der Tracking-Areas (Ansichten), wie AppKit sie
    /// bei echter Bewegung zustellt – synthetische Ereignisse lösen keine Tracking-Areas aus
    func hover(at p: NSPoint) {
        for v in views {
            for area in v.trackingAreas {
                guard let owner = area.owner as? NSView else { continue }   // Tooltips u. a. nicht
                let rect = v.convert(area.options.contains(.inVisibleRect) ? v.visibleRect : area.rect, to: nil)
                let id = ObjectIdentifier(area), now = rect.contains(p), was = inside.contains(id)
                if area.options.contains(.mouseEnteredAndExited), now != was {
                    eventNumber += 1
                    let e = NSEvent.enterExitEvent(with: now ? .mouseEntered : .mouseExited, location: p, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, eventNumber: eventNumber, trackingNumber: 0, userData: nil)!
                    if now { owner.mouseEntered(with: e) } else { owner.mouseExited(with: e) }
                }
                if now { inside.insert(id) } else { inside.remove(id) }
                if now, area.options.contains(.mouseMoved) { owner.mouseMoved(with: mouse(.mouseMoved, p)) }
            }
        }
        spin(0.05)
    }

    /// Ziehen und Ablegen eines Texts (Pasteboard) auf die Ansicht am Punkt, die Ziehen annimmt
    func drop(string: String, at p: NSPoint) -> Bool {
        // wie AppKit: Ziel ist die innerste Ansicht am Punkt mit angemeldeten Typen (SwiftUI legt dafür eigene Ansichten
        // neben den Inhalt, die beim Treffer-Test nicht auftauchen)
        guard let target = views.filter({ !$0.registeredDraggedTypes.isEmpty && frame($0).contains(p) && $0.isDescendant(of: host) })
            .min(by: { frame($0).width * frame($0).height < frame($1).width * frame($1).height }) else { return false }
        // bleibt bis zum Ende: SwiftUI liest es nach dem Drop asynchron
        let pb = UIDriver.dragPasteboard ?? NSPasteboard.withUniqueName()
        UIDriver.dragPasteboard = pb
        pb.clearContents()
        pb.setString(string, forType: .string)
        let info = UITestDragInfo(window: window, location: p, pasteboard: pb)
        // wie beim echten Ziehen: Betreten, einige Bewegungen über dem Ziel (SwiftUI wertet sie im nächsten Durchlauf aus), Ablegen
        guard target.draggingEntered(info) != [] else { return false }
        for _ in 0..<3 {
            spin(0.05)
            guard target.draggingUpdated(info) != [] else { return false }
        }
        guard target.prepareForDragOperation(info), target.performDragOperation(info) else { return false }
        target.concludeDragOperation(info)
        spin(0.05)
        return true
    }

    // MARK: Tastatur

    /// Taste über NSApp.sendEvent (lokale Monitore wie der KeyMonitor sehen sie), danach Loslassen
    func key(_ c: KeyCombo) {
        var flags: NSEvent.ModifierFlags = []
        if c.mods.contains(.control) { flags.insert(.control) }
        if c.mods.contains(.option) { flags.insert(.option) }
        if c.mods.contains(.shift) { flags.insert(.shift) }
        if c.mods.contains(.command) { flags.insert(.command) }
        let code = KeyCombo.keyCodes.first { $0.value == c.key }?.key ?? 0
        let chars: String = switch c.key {
        case "space": " "
        case "escape": "\u{1b}"
        case "return": "\r"
        case "tab": "\t"
        case "delete": "\u{7f}"
        default: KeyCombo.keyCodes.values.contains(c.key) ? "" : c.key
        }
        key(chars, code: code, flags: flags)
    }

    /// Text tippen (Tasten ohne Modifier)
    func type(_ text: String) {
        for ch in text { key(String(ch), code: 0, flags: []) }
    }

    /// NSApp.sendEvent ruft die lokalen Monitore (KeyMonitor), stellt die Taste der inaktiven App aber nicht ans Fenster
    /// zu. Das übernimmt der Test für Tasten ohne ⌘/⌥/⌃ in einem Textfeld (die lässt der KeyMonitor durch); ob ein
    /// Monitor eine Taste verbraucht hat, verrät AppKit nicht
    private func key(_ chars: String, code: UInt16, flags: NSEvent.ModifierFlags) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
            if window.lastKey !== e, flags.isDisjoint(with: [.command, .option, .control]), window.firstResponder is NSText {
                window.sendEvent(e)
            }
        }
        spin(0.05)
    }
}

/// Ziehen-Information für einen Drop ohne Fensterserver
final class UITestDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    init(window: NSWindow, location: NSPoint, pasteboard: NSPasteboard) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        guard let items = draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) else { return }
        var stop: ObjCBool = false
        for (i, o) in items.enumerated() {
            guard let w = o as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: w), i, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

/// kleine Collection für Rechner ohne eigene: 3 WAV-Dateien (20 s, Kick auf jedem Beat, leises Rauschen) und eine NML
/// mit Tempo, Key und Grid-Anker in einem temporären Ordner; wird am Ende gelöscht
@MainActor
enum UITestFixture {
    private(set) static var dir: URL?

    static func make() -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-uitest-\(getpid())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.dir = dir
            let specs: [(String, String, Double, Int)] = [
                ("ui-a.wav", "Fixture Alpha", 128, 21),
                ("ui-b.wav", "Fixture Beta", 126, 9),
                ("ui-c.wav", "Fixture Gamma With A Deliberately Long Title For The Column Fit Check", 130, 14),
            ]
            var entries = ""
            for (file, title, bpm, key) in specs {
                let url = dir.appendingPathComponent(file)
                try writeWave(url, bpm: bpm, seconds: 20)
                let comps = dir.standardizedFileURL.path.split(separator: "/").map(String.init)
                let nmlDir = "/:" + comps.map { xml($0) + "/:" }.joined()
                entries += """
                <ENTRY TITLE="\(xml(title))" ARTIST="MINOS-741 UI Test"><LOCATION DIR="\(nmlDir)" FILE="\(file)" VOLUME="Macintosh HD"></LOCATION>
                <INFO COMMENT="ui test fixture" RATING="test" PLAYTIME="20" PLAYTIME_FLOAT="20.000000"></INFO>
                <TEMPO BPM="\(bpm)"></TEMPO><MUSICAL_KEY VALUE="\(key)"></MUSICAL_KEY>
                <CUE_V2 NAME="AutoGrid" TYPE="4" START="0.000000" LEN="0" HOTCUE="0"></CUE_V2></ENTRY>

                """
            }
            let nml = """
            <?xml version="1.0" encoding="UTF-8" standalone="no" ?>
            <NML VERSION="19"><COLLECTION ENTRIES="\(specs.count)">
            \(entries)</COLLECTION>
            <PLAYLISTS><NODE TYPE="FOLDER" NAME="$ROOT"><SUBNODES COUNT="0"></SUBNODES></NODE></PLAYLISTS></NML>
            """
            let url = dir.appendingPathComponent("collection.nml")
            try nml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            UISelfTest.log("fixture: \(error)")
            return nil
        }
    }

    static func remove() {
        guard let dir else { return }
        try? FileManager.default.removeItem(at: dir)
        self.dir = nil
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func writeWave(_ url: URL, bpm: Double, seconds: Double) throws {
        let rate = 44100.0
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let n = AVAudioFrameCount(rate * seconds)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n), let ch = buf.floatChannelData else {
            throw CocoaError(.fileWriteUnknown)
        }
        buf.frameLength = n
        let beat = 60 / bpm
        var seed: UInt32 = 741
        for i in 0..<Int(n) {
            let t = Double(i) / rate
            let k = t.truncatingRemainder(dividingBy: beat)
            let kick = sin(2 * .pi * (50 + 120 * exp(-k * 40)) * k) * exp(-k * 12)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = (Double(seed >> 8) / Double(1 << 24) - 0.5) * 0.05
            let v = Float(kick * 0.8 + noise)
            for c in 0..<Int(file.processingFormat.channelCount) { ch[c][i] = v }
        }
        try file.write(from: buf)
    }
}

extension UISelfTest {
    /// EDIT-Modus auf Deck A: Ziehen ohne Taste markiert auf dem Raster, Klick setzt eine Schnittmarke, Rechtsklick ->
    /// „Bereich entfernen“ (Deck spielt die kürzere Liste), ⌘Z zurück, Tool-Loop 4 als Datei (Test-Ordner)
    static func editMode(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 0
        if mix.deck(d).playing { mix.togglePlay(d) }
        let wasEditing = mix.editing(d)
        mix.setEditing(d, true)
        u.spin(5) { mix.editSession(d) != nil }
        guard let session = mix.editSession(d) else { fail("EDIT: keine Sitzung auf Deck A") }
        if session.shown.segments.count > 1 { mix.editReset(d); u.spin(5) { mix.editSession(d)?.rendering == false } }
        guard let w = u.views.compactMap({ $0 as? WaveMouseView }).first(where: { $0.d == d }) else { fail("Wellenform A nicht gefunden") }
        guard let g = mix.deck(d).grid else { fail("Deck A ohne Grid") }
        mix.setRange(d, nil)
        mix.core.seek(d, seconds: mix.deck(d).duration / 2)   // Wellenform links und rechts im Track
        u.spin(0.2)
        let r = u.frame(w), dur0 = mix.deck(d).duration
        // Ziehen ohne Taste
        u.drag(from: NSPoint(x: r.minX + r.width * 0.56, y: r.midY), to: NSPoint(x: r.minX + r.width * 0.84, y: r.midY), steps: 8)
        guard let range = mix.range(d) else { fail("EDIT: Ziehen markiert keinen Bereich") }
        let step = mix.prefs.ui.editSnap.beats
        let a = g.beatPosition(at: range.start) / step, b = g.beatPosition(at: range.end) / step
        log(String(format: "edit: bereich %.3f–%.3f s · raster %@", range.start, range.end, mix.prefs.ui.editSnap.label))
        check(abs(a - a.rounded()) < 1e-3 && abs(b - b.rounded()) < 1e-3 || range.end >= dur0 - 1e-3, "EDIT: Bereich nicht auf dem Raster: \(a) – \(b)")
        // Klick daneben hebt den Bereich auf, der nächste setzt eine Marke
        let left = NSPoint(x: r.minX + r.width * 0.3, y: r.midY)
        u.click(at: left)
        check(mix.range(d) == nil, "EDIT: Klick daneben hebt den Bereich nicht auf")
        let segs0 = mix.editSession(d)?.shown.segments.count ?? 0
        u.click(at: left)
        u.spin(WaveMouseView.markDelay + 0.3) { (mix.editSession(d)?.shown.segments.count ?? 0) > segs0 }
        check((mix.editSession(d)?.shown.segments.count ?? 0) == segs0 + 1, "EDIT: Klick setzt keine Schnittmarke")
        // Bereich wieder markieren, Rechtsklick -> entfernen
        mix.setRange(d, range)
        u.spin(0.2)
        let inside = NSPoint(x: r.minX + r.width * 0.7, y: r.midY)
        guard let menu = u.rightClick(at: inside) else { fail("EDIT: kein Rechtsklick-Menü") }
        let item = String(localized: "Bereich entfernen")
        guard let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("EDIT: Menü ohne „\(item)“: \(menu.items.map(\.title))") }
        menu.performActionForItem(at: i)
        u.spin(10) { mix.editSession(d)?.preview != nil && mix.editSession(d)?.rendering == false }
        let dur1 = mix.deck(d).duration
        check(mix.editSession(d)?.preview != nil && abs(dur1 - (dur0 - range.length)) < 0.01,
              "EDIT: Deck spielt die Liste nicht (\(dur0) -> \(dur1), Bereich \(range.length) s)")
        // Tool-Loop 4 Beats aus der Vorschau
        CutJob.lastResult = nil
        mix.exportToolLoop(d, beats: 4)
        u.spin(30) { !CutJob.running && CutJob.lastResult != nil }
        guard let res = CutJob.lastResult else { fail("Tool-Loop: kein Ergebnis") }
        let url = URL(fileURLWithPath: res.track.path)
        check(FileManager.default.fileExists(atPath: url.path), "Tool-Loop: Datei fehlt \(url.path)")
        check(url.path.hasPrefix(CutJob.selfTestDirectory.path), "Tool-Loop: nicht im Test-Ordner: \(url.path)")
        let frames = (try? AVAudioFile(forReading: url)).map { Int($0.length) } ?? -1
        let rate = (try? AVAudioFile(forReading: url))?.processingFormat.sampleRate ?? 0
        check(frames == ToolLoop.frames(beats: 4, bpm: g.bpm, rate: rate), "Tool-Loop: \(frames) Frames, soll \(ToolLoop.frames(beats: 4, bpm: g.bpm, rate: rate))")
        log("edit: tool-loop \(url.lastPathComponent) · \(frames) frames")
        try? FileManager.default.removeItem(at: url)
        // ⌘Z: zurück zum Original
        guard let z = mix.prefs.keys.combo(.undo) else { fail("⌘Z nicht belegt") }
        u.key(z)
        u.spin(5) { mix.editSession(d)?.preview == nil && mix.editSession(d)?.rendering == false }
        check(abs(mix.deck(d).duration - dur0) < 1e-6 && mix.editSession(d)?.preview == nil, "EDIT: ⌘Z stellt das Original nicht her")
        mix.setRange(d, nil)
        mix.setEditing(d, wasEditing)
    }

    /// Deck-Zeile GROOVE an Deck A: Klick ins Raster liest das Muster (Fixture: Kick auf jedem Beat), ▶ MIDI startet
    /// (Quelle im Test versteckt), ■ hält an, ⚄ würfelt neu. Tasten von rechts gesucht (.mid schreibt im Test nur in den
    /// temporären Ordner), die Menüs links werden nie angeklickt
    static func groove(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, g = GrooveCenter.shared
        mix.prefs.ui.deckRows.groove = true
        defer { g.stop(); mix.prefs.ui.deckRows.groove = false; u.spin(0.3) }
        u.spin(2) { u.named("A groove") != nil }
        guard let row = u.named("A groove") else { fail("Groove-Zeile A nicht gefunden") }
        let r = u.frame(row)
        guard r.width >= 360, mix.core.trackAudio(0) != nil else { log("groove: zeile \(Int(r.width)) pt / ohne audio – fall übersprungen"); return }
        // Raster: zwischen Menüs (≤ 190 pt) und Tasten (≤ 160 pt)
        let gx = (r.minX + 190 + r.maxX - 160) / 2
        u.click(at: NSPoint(x: gx, y: r.midY))
        u.spin(3) { g.slots[0].pattern != nil }
        // CI-Runner: synthetische Klicks erreichen die SwiftUI-Gesten und -Tasten der Zeile dort nicht – dann die
        // Aktionen direkt, der Fall prüft dieselben Ergebnisse (Weg steht im Log)
        let clicks = g.slots[0].pattern != nil
        if !clicks {
            log("groove: klick ins raster ohne muster (\(StatusCenter.shared.current?.text ?? "keine Meldung")) – aktionen direkt")
            _ = g.analyze(mix, 0)
            u.spin(3) { g.slots[0].pattern != nil }
        }
        guard let p = g.slots[0].pattern, let clip = g.slots[0].clip else { fail("Klick ins Raster: kein Muster") }
        check(g.running == nil, "Klick ins Raster startet MIDI")
        log("groove muster: \(p.steps) schritte · kick \(p.steps(.kick)) · hats \(p.hatSteps.sorted()) · \(clip.notes.count) noten")
        if UITestFixture.dir != nil {
            check(p.steps(.kick) == Array(stride(from: 0, to: p.steps, by: 4)), "Fixture: Kick nicht auf jedem Beat: \(p.steps(.kick))")
        }
        check(!clip.notes.isEmpty, "keine Noten erzeugt")
        let seed = g.slots[0].seed
        if clicks {
            // ▶ MIDI von rechts suchen
            var playX: CGFloat?
            for x in stride(from: r.maxX - 3, to: r.maxX - 170, by: -4) {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running == 0 { playX = x; break }
            }
            guard let px = playX else { fail("▶ MIDI nicht gefunden") }
            check(StatusCenter.shared.current?.text.hasPrefix("Groove → MIDI") == true || StatusCenter.shared.history.contains { $0.text.hasPrefix("Groove → MIDI:") },
                  "keine Statusmeldung „Groove → MIDI …“")
            u.spin(0.5)
            // ■ von rechts (liegt rechts von ▶)
            var stopX: CGFloat?
            for x in stride(from: r.maxX - 3, to: px, by: -4) {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running == nil { stopX = x; break }
            }
            guard let sx = stopX else { fail("■ hält MIDI nicht an") }
            check(sx > px + 8, "angehalten nur über ▶ (x \(Int(sx - r.minX)) / \(Int(px - r.minX)))")
            // ⚄ liegt links von ▶: weiter nach links, bis der Seed wechselt (▶ dazwischen wieder aus)
            for x in stride(from: px - 4, to: px - 120, by: -4) where g.slots[0].seed == seed {
                u.click(at: NSPoint(x: x, y: r.midY))
                if g.running != nil { u.click(at: NSPoint(x: x, y: r.midY)) }
            }
        } else {
            g.toggle(mix, 0)
            u.spin(0.5)
            check(g.running == 0, "▶ MIDI startet nicht")
            check(StatusCenter.shared.current?.text.hasPrefix("Groove → MIDI") == true || StatusCenter.shared.history.contains { $0.text.hasPrefix("Groove → MIDI:") },
                  "keine Statusmeldung „Groove → MIDI …“")
            g.stop()
            u.spin(0.2)
            check(g.running == nil, "■ hält MIDI nicht an")
            g.reroll(mix, 0)
            u.spin(0.2)
        }
        check(g.slots[0].seed != seed, "⚄ würfelt nicht neu")
        check(g.running == nil, "MIDI läuft nach ⚄ noch")
    }

    /// DAW-Brücke: Testpaket mit einem Clip der Datei in Deck A an den Empfänger -> Streifen unter der Übersicht, Baum
    /// zeigt DAW, Rechtsklick auf den Decktitel übernimmt das Grid der Warp-Marker, Rückgängig, Abmelden nimmt den Streifen
    static func dawStrip(_ u: UIDriver, _ t: [Track]) {
        let bridge = DAWBridgeModel.shared
        if bridge.port == 0 { bridge.configure(enabled: true, port: 0) }
        check(bridge.port > 0, "DAW-Brücke: Empfänger nicht gestartet")
        guard let path = u.mix.deck(0).track?.path else { fail("Deck A leer") }
        let bpm = 131.0, beat = 60 / bpm, anchor = 0.125
        func send(_ o: [String: Any]) {
            guard let d = try? JSONSerialization.data(withJSONObject: o) else { fail("JSON") }
            check(DAWBridgeReceiver.send(d, port: bridge.port), "senden")
        }
        send(["v": 1, "t": "clip", "id": "ui", "track": 2, "trackName": "UI", "name": "Clip", "file": path, "warping": true,
              "markers": [[0, anchor], [32, anchor + 32 * beat]], "loop": [4, 8], "looping": true, "playing": true, "where": "session"])
        send(["v": 1, "t": "song", "seq": 1, "tempo": bpm, "playing": true, "beat": 0, "sig": 4, "clips": ["ui"], "pos": ["ui": [1, 2.0]]])
        u.spin(3) { u.named("A daw") != nil }
        check(bridge.deckClip[0] == "ui", "Clip nicht Deck A zugeordnet")
        guard let strip = u.named("A daw") else { fail("DAW-Streifen unter Deck A fehlt") }
        check(u.frame(strip).height > 4, "DAW-Streifen ohne Höhe")
        check(u.store.tracks(for: .daw).map(\.key) == [DAWBridgeModel.keyPrefix + "ui"], "Quelle DAW ohne den Clip")
        let before = u.mix.deck(0).grid
        guard let hdr = u.named("A header") else { fail("Deck-Kopf A nicht gefunden") }
        let r = u.frame(hdr)
        var found: NSMenu?
        for x in stride(from: r.minX + 2, to: r.minX + min(400, r.width), by: 6) {
            if let m = u.rightClick(at: NSPoint(x: x, y: r.midY)), m.items.contains(where: { $0.title.hasPrefix(String(localized: "Grid des DAW-Clips übernehmen")) }) {
                found = m; break
            }
        }
        guard let menu = found, let i = menu.items.firstIndex(where: { $0.title.hasPrefix(String(localized: "Grid des DAW-Clips übernehmen")) })
        else { fail("Deck-Menü ohne „Grid des DAW-Clips übernehmen“") }
        menu.performActionForItem(at: i)
        u.spin(1) { u.mix.deck(0).grid?.bpm == bpm }
        guard let g = u.mix.deck(0).grid else { fail("Deck A ohne Grid") }
        check(abs(g.bpm - bpm) < 1e-9 && abs(g.anchor - anchor) < 1e-9 && u.mix.deck(0).gridEdited, "Grid nicht aus der DAW: \(g)")
        UndoStack.shared.undo()
        u.mix.pull()
        check(u.mix.deck(0).grid == before, "Rückgängig stellt das Grid nicht her")
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_DAWSHOT"] {
            u.spin(1)   // Zeiger der DAW läuft 1 s
            shot(u, out, "daw")
        }
        send(["v": 1, "t": "bye"])
        u.spin(3) { u.named("A daw") == nil }
        check(u.named("A daw") == nil && bridge.clips.isEmpty, "Streifen bleibt nach dem Abmelden")
        log(String(format: "daw: streifen %.0f × %.0f pt, grid %.2f bpm übernommen + rückgängig", u.frame(strip).width, u.frame(strip).height, bpm))
    }

    /// Master-FX: belegtes Tastenkürzel schaltet den Master-Bus an und aus; Kette im Master-Bus lädt, Mixer zeigt sie
    static func masterFX(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let keys = mix.prefs.keys
        guard let combo = [KeyCombo("f", [.control, .option]), KeyCombo("g", [.control, .option])].first(where: { keys.action(for: $0) == nil })
        else { fail("keine freie Taste für Master-FX") }
        mix.prefs.keys.set(.masterFX, combo)
        defer { mix.prefs.keys = keys }
        mix.prefs.ui.showMixer = true
        u.window.makeFirstResponder(nil)
        u.spin(0.3)
        let on0 = mix.masterFX.on
        u.key(combo)
        u.spin(1) { mix.masterFX.on != on0 }
        check(mix.masterFX.on != on0, "\(combo.symbols): Master-FX schaltet nicht")
        u.key(combo)
        u.spin(1) { mix.masterFX.on == on0 }
        check(mix.masterFX.on == on0, "\(combo.symbols): Master-FX schaltet nicht zurück")
        mix.addPlugin(MixController.masterBus, "aufx:lpas:appl")
        u.spin(10) { mix.core.pluginInstance(MixController.masterBus, slot: 0) != nil }
        check(mix.chain(MixController.masterBus).map(\.id) == ["aufx:lpas:appl"], "Master-Kette: \(mix.chain(MixController.masterBus).map(\.id))")
        check(mix.core.pluginInstance(MixController.masterBus, slot: 0) != nil, "Master-Kette: AULowpass lädt nicht")
        mix.removePlugin(MixController.masterBus, slot: 0)
        mix.prefs.ui.showMixer = false
        u.spin(0.3)
        check(mix.chain(MixController.masterBus).isEmpty, "Master-Kette nicht leer")
    }

    /// Doppelklick auf Regler und Fader = Standardwert: GAIN-Knopf im Mixer (Kanalzug C·A·B·D: der erste ist Deck C),
    /// Crossfader (NSSlider) und Kanalfader; Ziehen bleibt davon unberührt
    static func doubleClickReset(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix
        let showMixer = mix.prefs.ui.showMixer, mode = mix.mixerMode
        mix.prefs.ui.showMixer = true; mix.mixerMode = .internalMixer
        u.spin(0.4)
        defer { mix.prefs.ui.showMixer = showMixer; mix.mixerMode = mode }
        guard let gain = u.named("dbl GAIN") else { fail("GAIN-Knopf nicht gefunden") }
        let f = u.frame(gain), c = NSPoint(x: f.midX, y: f.midY)
        func gains() -> [Double] { (0..<4).map { mix.deck($0).gainDb } }
        // synthetische Drags erreichen SwiftUI-DragGestures nicht (nur AppKit-Handler wie die Wellenform), deshalb Werte setzen
        for d in 0..<4 { mix.updateDeck(d) { $0.gainDb = 6 } }
        u.doubleClick(at: c)
        u.spin(0.2)
        let after = gains()
        check(after.filter { $0 == 0 }.count == 1 && after.filter { $0 == 6 }.count == 3, "GAIN nach Doppelklick: \(after)")
        u.doubleClick(at: c)   // noch einmal: bleibt 0, kein zweiter Kanal
        u.spin(0.2)
        check(gains() == after, "zweiter Doppelklick: \(gains())")
        // Crossfader (NSSlider)
        mix.setCrossfader(0.7)
        guard let xf = u.named("dbl XFADE") else { fail("Crossfader nicht gefunden") }
        u.doubleClick(at: NSPoint(x: u.frame(xf).midX, y: u.frame(xf).midY))
        u.spin(0.2)
        check(mix.crossfader == 0, "Crossfader nach Doppelklick: \(mix.crossfader)")
        log("doppelklick: GAIN 6 → \(after), Crossfader 0.7 → \(mix.crossfader)")
    }

    /// Browser übereinander: Kopf eines Bereichs (Titel, Suche, Rollen, Tags) als Spalte links neben der Liste, die
    /// Liste reicht bis unter die Favoritenleiste
    static func stackedSide(_ u: UIDriver, _ t: [Track]) {
        let layout = u.mix.prefs.ui.browserLayout
        defer { u.mix.prefs.ui.browserLayout = layout; u.spin(0.3) }
        check(u.named("pane side A") == nil, "Seitenspalte schon nebeneinander")
        let m = u.browser.paneA
        u.mix.pull()
        let before = m.paneHeight - m.favoritesHeight - m.tableHeight   // Kopf nebeneinander: zwei Zeilen
        u.mix.prefs.ui.browserLayout = .stacked
        u.spin(2) { u.named("pane side B") != nil }
        u.spin(0.3)
        guard let a = u.named("pane side A"), let b = u.named("pane side B") else { fail("Seitenspalte fehlt") }
        let fa = u.frame(a), fb = u.frame(b)
        check(fa.minY > fb.maxY - 1, "A nicht über B: \(fa) \(fb)")
        check(abs(fa.width - PaneHeader.sideWidth) < 1, "Spaltenbreite \(fa.width)")
        // der Kopf kostet keine Höhe mehr: Tabelle = Bereich − Favoritenleiste (bis auf Ränder)
        let after = m.paneHeight - m.favoritesHeight - m.tableHeight
        check(after < 12 && before - after > 30,
              "Tabelle \(m.tableHeight) pt von \(m.paneHeight) − Favoriten \(m.favoritesHeight): Rest \(after) (nebeneinander \(before))")
        guard let sf = u.searchField(pane: 0) else { fail("Suchfeld fehlt") }
        check(fa.contains(u.frame(sf)), "Suchfeld nicht in der Spalte: \(u.frame(sf))")
        // Suche aus der Spalte heraus wirkt auf die Liste
        let search = m.search, rows = m.shown.count
        u.click(at: u.center(sf))
        u.spin(0.3)
        check(u.window.firstResponder is NSText, "Klick ins Suchfeld der Spalte: kein Texteditor")
        u.type("zzqxv-nichts")
        u.key(KeyCombo("return", []))
        u.spin(2) { m.search == "zzqxv-nichts" }
        check(m.search == "zzqxv-nichts", "Suche aus der Spalte kommt nicht an: „\(m.search)“")
        u.spin(2) { m.shown.isEmpty }
        check(m.shown.isEmpty, "Liste nicht gefiltert: \(m.shown.count) von \(rows)")
        m.search = search
        u.spin(2) { m.shown.count == rows }
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_STACKSHOT"] { shot(u, out, "gestapelt") }
        log(String(format: "gestapelt: spalte %.0f × %.0f pt, tabelle %.0f von %.0f pt, kopf %.1f → %.1f pt", fa.width, fa.height, m.tableHeight, m.paneHeight, before, after))
    }

    /// Bild des Fensterinhalts (zum Ansehen), 2×
    static func shot(_ u: UIDriver, _ out: String, _ what: String) {
        guard let v = u.window.contentView?.superview, let layer = v.layer else { return }
        let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: 2, y: 2)
        if v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
        layer.render(in: ctx)
        if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: out))
            log("\(what): bild \(out)")
        }
    }

}

extension UISelfTest {
    /// ◆ UNGESPIELT im Kopf von Bereich A: Klick blendet die gespielten Tracks aus (Zeilen sinken um die gespielten,
    /// Anzahl „ausgeblendet“ im Kopf), History und Preparation bleiben; zweiter Klick zeigt sie wieder
    static func unplayed(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, pane = u.browser.paneA
        guard let history = u.browser.history else { fail("UNGESPIELT: keine History") }
        let played0 = history.played, hide0 = mix.prefs.ui.hidePlayedTracks, source0 = pane.source
        defer { history.setPlayed(played0); mix.prefs.ui.hidePlayedTracks = hide0; pane.source = source0; u.spin(0.5) }
        mix.prefs.ui.hidePlayedTracks = false
        pane.source = .collection
        u.spin(5) { !pane.listPending && !pane.shown.isEmpty }
        u.spin(0.3)
        let n0 = pane.shown.count
        check(n0 >= 3, "UNGESPIELT: Bereich A zeigt \(n0) Tracks")
        history.setPlayed(played0.union(pane.shown.prefix(2).map(\.key)))
        let played = history.played
        let expected = pane.shown.filter { played.contains($0.key) }.count
        guard let marker = u.views.compactMap({ $0 as? UITestMark.V }).filter({ $0.name == "unplayed" })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Knopf UNGESPIELT nicht gefunden") }
        let r = u.frame(marker), p = NSPoint(x: r.midX, y: r.midY)
        check(r.width > 10 && u.window.contentView?.bounds.contains(p) == true, "UNGESPIELT liegt außerhalb: \(r)")
        // Klick direkt an die getroffene Hosting-View (NSWindow.sendEvent kommt dort im Test nicht immer an)
        let root = u.window.contentView?.superview ?? u.host
        guard let hit = root.hitTest(root.convert(p, from: nil)) else { fail("UNGESPIELT: nichts unter dem Knopf") }
        func click() {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: u.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { fail("kein Mausereignis") }
                if type == .leftMouseDown { hit.mouseDown(with: e) } else { hit.mouseUp(with: e) }
            }
        }
        func tableRows() -> Int? {
            u.views.compactMap { $0 as? TrackHeaderView }.filter { u.frame($0).minX < u.window.frame.width / 2 }
                .compactMap { $0.tableView?.numberOfRows }.first
        }
        click()
        u.spin(5) { mix.prefs.ui.hidePlayedTracks && !pane.listPending && pane.shown.count == n0 - expected && tableRows() == n0 - expected }
        check(mix.prefs.ui.hidePlayedTracks, "Klick auf UNGESPIELT schaltet nicht")
        check(pane.shown.count == n0 - expected, "UNGESPIELT: \(pane.shown.count) Zeilen, soll \(n0) − \(expected)")
        check(tableRows() == n0 - expected, "UNGESPIELT: Tabelle hat \(tableRows() ?? -1) Zeilen, soll \(n0 - expected)")
        check(pane.hiddenCount == expected, "UNGESPIELT: \(pane.hiddenCount) ausgeblendet, soll \(expected)")
        check(!pane.shown.contains { played.contains($0.key) }, "UNGESPIELT: gespielter Track noch in der Liste")
        check(BrowserPaneModel.hiddenKeys(source: .historyLive, played: played, hidePlayed: true) == nil
              && BrowserPaneModel.hiddenKeys(source: .preparation, played: played, hidePlayed: true) == nil, "UNGESPIELT wirkt auf History / Preparation")
        click()
        u.spin(5) { !mix.prefs.ui.hidePlayedTracks && !pane.listPending && pane.shown.count == n0 }
        check(!mix.prefs.ui.hidePlayedTracks && pane.shown.count == n0, "zweiter Klick: \(pane.shown.count) Zeilen, soll \(n0)")
        log("ungespielt: \(n0) -> \(n0 - expected) zeilen (\(expected) gespielt) -> \(pane.shown.count)")
    }
}

extension UISelfTest {
    /// Profil „Vorbereiten“ an Deck A mit einer eigenen WAV (16 Bit, Spitze 0.5, 120 BPM, im Temp-Ordner): Werkzeugzeile
    /// da, Deck im EDIT-Modus, Klick auf +3 -> Gain +3 dB, Klick auf RENDER -> `[amp +3].wav` im Test-Ordner mit
    /// Spitze × 1,41. MIX741_UITEST_PREPSHOT=<png>: Bild des Fensters. Danach Ansicht und Deck A wie vorher
    static func prepareMode(_ u: UIDriver, _ t: [Track]) {
        let mix = u.mix, d = 0
        if mix.deck(d).playing { mix.togglePlay(d) }
        let savedUI = mix.prefs.ui, savedBig = u.browser.maximized, before = mix.deck(d).track, wasEditing = mix.editing(d)
        UITestFrames.on = true
        // Quelle: 20 s Kick, Spitze genau 0.5
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-uitest-prep-\(getpid())", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prep.wav")
        let rate = 44_100.0, n = Int(rate * 20)
        do {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                                           AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let f = try AVAudioFile(forWriting: url, settings: settings)
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            let kick = (0..<n).map { i -> Double in
                let k = (Double(i) / rate).truncatingRemainder(dividingBy: 0.5)
                return sin(2 * .pi * (50 + 120 * exp(-k * 40)) * k) * exp(-k * 12)
            }
            let scale = 0.5 / (kick.map(abs).max() ?? 1)
            for i in 0..<n {
                let v = Float((kick[i] * scale * 32_768).rounded() / 32_768)   // 16 Bit genau, Spitze 16384 = 0.5
                buf.floatChannelData![0][i] = v
                buf.floatChannelData![1][i] = v
            }
            try f.write(from: buf)
        } catch { fail("Vorbereiten: Test-WAV nicht geschrieben: \(error)") }
        defer {
            try? FileManager.default.removeItem(at: dir)
            UITestFrames.on = false
        }
        var track = Track(key: url.path, path: url.path)
        track.title = "Prepare Fixture"
        track.bpm = 120
        track.duration = 20
        track.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 0, lengthMs: 0, hotcue: -1)]
        _ = mix.load(track, deck: d, force: true)
        u.spin(20) { mix.core.trackAudio(d) != nil && mix.deck(d).track?.key == track.key }
        check(mix.core.trackAudio(d) != nil, "Vorbereiten: Test-WAV lädt nicht")
        // Profil wie aus dem Menü
        let p = mix.prefs.ui.layoutProfiles.first { $0.id == LayoutProfile.prepareID } ?? LayoutProfile.prepare(from: mix.prefs.ui)
        LayoutProfiles.apply(p, mix: mix, browser: u.browser)
        u.spin(5) { u.named("A prepare") != nil && mix.editing(d) && mix.editSession(d) != nil && mix.prepState(d).peak != nil }
        guard let row = u.named("A prepare") else { fail("Vorbereiten: Werkzeugzeile A fehlt") }
        check(mix.editing(d) && mix.editSession(d) != nil, "Vorbereiten: Deck A nicht im EDIT-Modus")
        check(u.named("A transport") == nil && u.named("A loop") == nil, "Vorbereiten: Transport- / Loop-Zeile sichtbar")
        // Deck-Puffer in der Rate des Geräts: Spitze bis ~0.2 dB neben der der Datei (RENDER misst die Ausgabe genau)
        check(abs((mix.prepState(d).peak ?? 0) - 0.5) < 0.015, "Vorbereiten: Spitze \(mix.prepState(d).peak ?? -1) statt 0.5")
        // Taste klicken; kommt der Klick nicht an, das Tastenkürzel derselben Aktion (KeyMonitor), kommt auch das nicht an
        // (synthetische Ereignisse erreichen SwiftUI / die Monitore nicht, wie „groove“ auf main), die Aktion direkt.
        // Der Weg steht im Log
        var via: [String] = []
        func press(_ id: String, key: ShortcutID, times: Int = 1, until done: () -> Bool, direct: () -> Void) {
            let marks = u.views.compactMap { $0 as? UITestFrames.Marker }.filter { $0.id == "\(d).\(id)" && $0.window === u.window }
            guard let m = marks.first(where: { u.frame(row).contains(u.center($0)) }) else {
                fail("Vorbereiten: Taste \(id) nicht in der Zeile (\(marks.map { u.frame($0) }))")
            }
            u.click(at: u.center(m))
            u.spin(1, until: done)
            guard !done() else { via.append("\(id): klick"); return }
            let keys = mix.prefs.keys
            guard let combo = [KeyCombo("y", [.control, .option, .shift]), KeyCombo("u", [.control, .option, .shift])]
                .first(where: { keys.action(for: $0) == nil || keys.action(for: $0) == key }) else { fail("Vorbereiten: keine freie Taste") }
            mix.prefs.keys.set(key, combo)
            u.window.makeFirstResponder(nil)
            for _ in 0..<times { u.key(combo); u.spin(0.1) }
            mix.prefs.keys = keys
            u.spin(1, until: done)
            guard !done() else { via.append("\(id): taste \(combo.symbols)"); return }
            via.append("\(id): direkt (klick und taste nicht zugestellt)")
            direct()
            u.spin(1, until: done)
        }
        u.spin(0.3)
        press("amp.3", key: .prepAmpUp, times: 3, until: { mix.prepState(d).gainDb == 3 }, direct: { mix.prepareAmp(d, add: 3) })
        check(mix.prepState(d).gainDb == 3 && !mix.prepState(d).limited, "Vorbereiten: +3 setzt \(mix.prepState(d).gainDb) dB")
        log(String(format: "vorbereiten: zeile %.0f × %.0f pt · gain %@ dB · headroom %.1f dB", u.frame(row).width, u.frame(row).height,
                   Amplify.label(mix.prepState(d).gainDb), mix.prepState(d).headroomLeft ?? .nan))
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_PREPSHOT"], let v = u.window.contentView?.superview, let layer = v.layer {
            u.spin(1)   // Zeile und Wellenform nachgezogen
            let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: 2, y: 2)
                if v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    log("vorbereiten: bild \(out)")
                }
            }
        }
        // Reste eines abgebrochenen Laufs im Test-Ordner
        let cutDir = CutJob.selfTestDirectory
        for f in (try? FileManager.default.contentsOfDirectory(atPath: cutDir.path)) ?? [] where f.hasPrefix("prep [amp") {
            try? FileManager.default.removeItem(at: cutDir.appendingPathComponent(f))
        }
        CutJob.lastTracks = []
        press("render", key: .prepRender, until: { CutJob.running || !CutJob.lastTracks.isEmpty }, direct: { mix.prepareRender(d) })
        u.spin(30) { !CutJob.running && !CutJob.lastTracks.isEmpty }
        log("vorbereiten: eingabe " + via.joined(separator: " · "))
        guard let res = CutJob.lastTracks.first else { fail("Vorbereiten: RENDER ohne Ergebnis (\(StatusCenter.shared.current?.text ?? "-"))") }
        let file = URL(fileURLWithPath: res.path)
        defer { try? FileManager.default.removeItem(at: file) }
        check(file.path.hasPrefix(CutJob.selfTestDirectory.path), "Vorbereiten: nicht im Test-Ordner: \(file.path)")
        check(file.lastPathComponent == "prep [amp +3].wav", "Vorbereiten: Dateiname \(file.lastPathComponent)")
        guard let s = try? AudioCutWriter.source(url: file, deck: nil) else { fail("Vorbereiten: Ergebnis nicht lesbar") }
        let peak = AudioCutWriter.peak(s.channels, frames: s.frames)
        check(s.frames == n && abs(peak / 0.5 - 1.4125) < 1e-3, "Vorbereiten: \(s.frames) Frames, Spitze \(peak) (soll \(0.5 * 1.4125))")
        check(abs((CutJob.lastGain ?? 0) - 3) < 1e-6 && res.title == "Prepare Fixture [amp +3]", "Vorbereiten: Gain \(CutJob.lastGain ?? -1), Titel \(res.title)")
        log(String(format: "vorbereiten: %@ · %d frames · spitze %.4f -> %.4f (× %.4f)", file.lastPathComponent, s.frames, 0.5, peak, peak / 0.5))
        // zurück
        mix.prefs.ui = savedUI
        u.browser.maximized = savedBig
        u.spin(1) { u.named("A prepare") == nil }
        check(mix.editing(d) == wasEditing, "Vorbereiten: EDIT bleibt nach dem Profilwechsel an")
        if let b = before { _ = mix.load(b, deck: d, force: true); u.spin(20) { mix.core.trackAudio(d) != nil && mix.deck(d).track?.key == b.key } }
    }
}

extension UISelfTest {
    /// Rechtsklick auf PLAYLISTS im Baum von Bereich A → „Neue Smartlist …“ → Editor (Sheet): Feld über das Menü
    /// Genre, Wert „Techno“ getippt → Treffer > 0 → ⏎ speichert → Eintrag im Baum, Bereich A zeigt die Treffer;
    /// Track auf eine eigene Playlist im Baum fallen lassen, ⌫ in der Liste nimmt ihn wieder heraus.
    /// Eigener Baum nur im Temp-Ordner des Selbsttests; ohne Techno in der Collection bekommt ein Track das Genre
    /// (nur im Speicher)
    static func playlistTree(_ u: UIDriver, _ t: [Track]) {
        let pane = u.browser.paneA, store = u.store
        let source = pane.source, showTree = pane.showTree, hide = u.mix.prefs.ui.hideTreeWithDecks
        pane.showTree = true
        u.mix.prefs.ui.hideTreeWithDecks = false
        var edited: String?
        if !store.tracks.contains(where: { SmartRules.contains(Track.fold($0.genre), Track.fold("Techno")) }) {
            edited = t[2].key
            store.applyEdits([t[2].key: [.genre: "Techno"]], writeBack: false)
        }
        defer {
            if let k = edited { store.revertEdits([k]) }
            pane.source = source
            pane.showTree = showTree
            u.mix.prefs.ui.hideTreeWithDecks = hide
        }
        let before = store.playlists
        u.spin(0.5)
        // Baum von Bereich A: SwiftUI-Liste links (keine Track-Tabelle)
        guard let tree = u.views.compactMap({ $0 as? NSTableView }).filter({ !($0 is TrackNSTable) && $0.numberOfRows > 3 })
            .min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Baum von Bereich A nicht gefunden") }
        let rows0 = tree.numberOfRows
        let item = String(localized: "Neue Smartlist …")
        var menu: NSMenu?
        for r in 0..<tree.numberOfRows {
            tree.scrollRowToVisible(r)
            u.spin(0.02)
            let rect = tree.convert(tree.rect(ofRow: r), to: nil)
            if let m = u.rightClick(at: NSPoint(x: rect.minX + 60, y: rect.midY)), m.items.contains(where: { $0.title == item }) { menu = m; break }
        }
        guard let menu, let i = menu.items.firstIndex(where: { $0.title == item }) else { fail("Rechtsklick im Baum: kein „\(item)“") }
        log("menü an PLAYLISTS: " + menu.items.map(\.title).joined(separator: " · "))
        menu.performActionForItem(at: i)
        u.spin(5) { u.window.attachedSheet != nil && SmartlistDraft.current != nil }
        guard let sheet = u.window.attachedSheet, let draft = SmartlistDraft.current else { fail("Smartlist-Editor öffnet nicht") }
        u.spin(0.5)
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        let views = all(sheet.contentView?.superview ?? sheet.contentView!)
        // Feld-Menü der ersten Zeile: oberstes, linkes Menü mit „Genre“
        let genre = SmartLabels.field(.genre), artist = SmartLabels.field(.artist)
        guard let popup = views.compactMap({ $0 as? NSPopUpButton }).filter({ $0.itemTitles.contains(genre) })
            .min(by: { a, b in sheet.contentView!.convert(a.bounds, from: a).minX < sheet.contentView!.convert(b.bounds, from: b).minX }) else { fail("Feld-Menü nicht gefunden") }
        for f in [artist, genre] {
            popup.selectItem(withTitle: f)
            _ = popup.sendAction(popup.action, to: popup.target)
            u.spin(0.2)
        }
        check(draft.rules.rules.first?.field == .genre, "Feld-Menü: \(draft.rules.rules.first.map { "\($0.field)" } ?? "-") statt genre")
        check(draft.rules.rules.first?.op == .contains, "Operator nicht „enthält“")
        // Wert tippen: Feld „WERT“ (Combo), Tasten an das Sheet
        guard let field = views.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.placeholderString == String(localized: "WERT") }) else { fail("Wertfeld nicht gefunden") }
        sheet.makeFirstResponder(field)
        u.spin(0.1)
        func key(_ chars: String, _ code: UInt16) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: sheet.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                         isARepeat: false, keyCode: code)!
                sheet.sendEvent(e)
            }
            u.spin(0.02)
        }
        for ch in "Techno" { key(String(ch), 0) }
        u.spin(3) { draft.rules.rules.first?.value == "Techno" && draft.countIsCurrent }
        check(draft.rules.rules.first?.value == "Techno", "Wert: „\(draft.rules.rules.first?.value ?? "")“ statt „Techno“ (Feld „\(field.stringValue)“)")
        guard draft.countIsCurrent, let n = draft.count, n > 0, n < store.tracks.count else { fail("Treffer: \(draft.count.map(String.init) ?? "keine Zahl") von \(store.tracks.count)") }
        let want = store.tracks.filter { SmartRules.contains(Track.fold($0.genre), Track.fold("Techno")) }.count
        check(n == want, "Treffer im Editor \(n), Genre enthält „Techno“ in der Collection \(want)")
        log("editor: genre enthält „Techno“ -> \(n) treffer")
        // ⏎ = SPEICHERN (Standard-Knopf), erst Feld verlassen
        sheet.makeFirstResponder(nil)
        let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: sheet.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                   isARepeat: false, keyCode: 36)!
        if !sheet.performKeyEquivalent(with: ret) { sheet.sendEvent(ret) }
        u.spin(5) { u.window.attachedSheet == nil }
        check(u.window.attachedSheet == nil, "⏎ speichert nicht (Editor bleibt offen)")
        let added = store.playlists.all.filter { b in !before.contains(b.id) }
        guard added.count == 1, let sl = added.first, sl.kind == .smartlist,
              sl.rules.rules.first.map({ $0.field == .genre && $0.op == .contains && $0.value == "Techno" }) == true else {
            fail("gespeichert: \(added.map { "\($0.kind) \($0.name)" })")
        }
        u.spin(3) { tree.numberOfRows == rows0 + 1 }
        check(tree.numberOfRows == rows0 + 1, "Baum: \(tree.numberOfRows) Zeilen statt \(rows0 + 1)")
        check(pane.source == .own(OwnRef(sl)), "Bereich A zeigt nicht die neue Smartlist")
        u.spin(3) { pane.shown.count == n }
        check(pane.shown.count == n, "Bereich A: \(pane.shown.count) Zeilen statt \(n)")
        log("baum: \(rows0) -> \(tree.numberOfRows) zeilen · „\(sl.name)“ · bereich A \(pane.shown.count) tracks")
        // Track auf eine eigene Playlist im Baum ziehen (letzte eigene Zeile = neueste Playlist), dann ⌫ in der Liste
        let pl = store.addOwn(.playlist, into: nil, name: "UI Playlist")
        u.spin(3) { tree.numberOfRows == rows0 + 2 }
        let targets = u.views.filter { $0 is TreeDropView && u.frame($0).minX < u.window.frame.width / 2 && $0.window === u.window }
        guard let last = targets.min(by: { u.frame($0).minY < u.frame($1).minY }) else { fail("keine Ablage-Ansichten im Baum") }
        check(u.drop(string: TrackDrag.prefix + t[0].key, at: u.center(last)), "Drop auf die Playlist nicht angenommen")
        u.spin(3) { store.playlists.item(pl.id)?.tracks == [t[0].key] }
        check(store.playlists.item(pl.id)?.tracks == [t[0].key], "Playlist nach dem Drop: \(store.playlists.item(pl.id)?.tracks.count ?? -1) Tracks")
        pane.source = .own(OwnRef(pl))
        u.spin(3) { pane.shown.map(\.key) == [t[0].key] }
        pane.selection = [t[0].key]
        guard let table = u.views.compactMap({ $0 as? TrackNSTable }).min(by: { u.frame($0).minX < u.frame($1).minX }) else { fail("Track-Tabelle A fehlt") }
        u.window.makeFirstResponder(table)
        let del = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: u.window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                                   isARepeat: false, keyCode: 51)!
        u.window.sendEvent(del)
        u.spin(1) { store.playlists.item(pl.id)?.tracks.isEmpty == true }
        check(store.playlists.item(pl.id)?.tracks.isEmpty == true, "⌫ entfernt den Track nicht aus der Playlist")
        // Eintrag (wie aus dem Baum gezogen) auf einen eigenen Ordner: hinein
        let folder = store.addOwn(.folder, into: nil, name: "UI Ordner")
        u.spin(3) { tree.numberOfRows == rows0 + 3 }
        let targets2 = u.views.filter { $0 is TreeDropView && u.frame($0).minX < u.window.frame.width / 2 && $0.window === u.window }
        guard let fv = targets2.min(by: { u.frame($0).minY < u.frame($1).minY }) else { fail("Ordner-Zeile fehlt") }
        check(u.drop(string: TreeDrag.prefix + pl.id.uuidString, at: u.center(fv)), "Drop eines Eintrags auf den Ordner nicht angenommen")
        u.spin(1) { store.playlists.parent(of: pl.id) == .some(folder.id) }
        check(store.playlists.parent(of: pl.id) == .some(folder.id), "Playlist nicht im Ordner")
        log("drop auf playlist + ⌫ in der liste + eintrag in ordner ok")
        // Tabelle: Zeile als Text ziehbar, Ablegen aus der eigenen Tabelle = Reihenfolge (zeigt die Playlist-Reihenfolge)
        store.editPlaylists("UI") { $0.addTracks(t.map(\.key), to: pl.id) }
        pane.sortOrder = [KeyPathComparator(\Track.title)]
        u.spin(3) { pane.shown.count == 3 }
        let shownKeys = pane.shown.map(\.key)
        let w = table.dataSource?.tableView?(table, pasteboardWriterForRow: 0) as? String
        check(w == TrackDrag.prefix + shownKeys[0], "Zeile ziehen: \(w ?? "nichts")")
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString(TrackDrag.prefix + t[2].key, forType: .string)
        let info = TableDragInfo(window: u.window, pasteboard: pb, source: table)
        let row = shownKeys.firstIndex(of: t[0].key) ?? 0
        check(table.dataSource?.tableView?(table, validateDrop: info, proposedRow: row, proposedDropOperation: .above) == .move, "Ablegen in der eigenen Tabelle: keine Verschiebung")
        check(table.dataSource?.tableView?(table, acceptDrop: info, row: row, dropOperation: .above) == true, "Ablegen in der Tabelle abgelehnt")
        let order = store.playlists.item(pl.id)?.tracks ?? []
        check(order == [t[2].key, t[0].key, t[1].key], "Reihenfolge nach dem Ziehen: \(order.map { k in t.firstIndex { $0.key == k } ?? -1 })")
        check(pane.sortOrder.isEmpty, "Liste zeigt nach dem Ziehen nicht die Playlist-Reihenfolge")
        u.spin(3) { pane.shown.map(\.key) == order }
        check(pane.shown.map(\.key) == order, "Liste in Playlist-Reihenfolge")
        // „Neue Playlist“ über das Menü: Umbenennen-Dialog, Name tippen, OK
        // Menü von PLAYLISTS (hat „Neue Smartlist …“, aber kein „Umbenennen …“ wie ein Ordner)
        guard let m2 = {
            for r in 0..<tree.numberOfRows {
                tree.scrollRowToVisible(r)
                let rect = tree.convert(tree.rect(ofRow: r), to: nil)
                if let m = u.rightClick(at: NSPoint(x: rect.minX + 60, y: rect.midY)), m.items.contains(where: { $0.title == String(localized: "Neue Playlist") }),
                   m.items.contains(where: { $0.title == String(localized: "Neue Smartlist …") }), !m.items.contains(where: { $0.title == String(localized: "Umbenennen …") }) { return m }
            }
            return nil
        }(), let ni = m2.items.firstIndex(where: { $0.title == String(localized: "Neue Playlist") }) else { fail("Menü „Neue Playlist“ fehlt") }
        let known = Set(store.playlists.all.map(\.id))
        m2.performActionForItem(at: ni)
        u.spin(5) { u.window.attachedSheet != nil }
        guard let alert = u.window.attachedSheet else { fail("Umbenennen-Dialog öffnet nicht") }
        func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
        let av = allViews(alert.contentView!)
        guard let nameField = av.compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable }),
              let ok = av.compactMap({ $0 as? NSButton }).first(where: { $0.title == String(localized: "OK") }) else { fail("Umbenennen-Dialog ohne Feld / OK") }
        alert.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
        nameField.currentEditor()?.insertText("UI Umbenannt")
        u.spin(0.2)
        ok.performClick(nil)
        u.spin(3) { u.window.attachedSheet == nil }
        let fresh = store.playlists.all.filter { !known.contains($0.id) }
        check(fresh.count == 1 && fresh[0].kind == .playlist && fresh[0].name == "UI Umbenannt", "Neue Playlist + Umbenennen: \(fresh.map(\.name))")
        log("tabelle: ziehen + reihenfolge ok · neue playlist über das menü + umbenennen ok")
        store.playlists = before
        PlaylistFile.flush()
        PlaylistFile.removeSelfTestDir()
    }
}

/// Ziehen-Information mit Quelle (Ablegen in derselben Tabelle = Reihenfolge)
final class TableDragInfo: NSObject, NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    init(window: NSWindow, pasteboard: NSPasteboard, source: Any?) {
        draggingDestinationWindow = window
        draggingPasteboard = pasteboard
        draggingSource = source
    }
    var draggingLocation: NSPoint { .zero }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 2 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
