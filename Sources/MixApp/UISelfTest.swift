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
            ("daw-streifen", dawStrip),
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
        let r = u.frame(w)
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
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown || e.type == .keyUp { lastKey = e }
        super.sendEvent(e)
    }
}

/// NSApp.keyWindow im Test: das Testfenster (Klasse von NSApp nur in diesem Prozess getauscht, keine eigenen Felder)
final class UITestApplication: NSApplication {
    nonisolated(unsafe) static weak var testWindow: NSWindow?
    override var keyWindow: NSWindow? { Self.testWindow ?? super.keyWindow }
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

    /// Klick: Loslassen vorab in die Warteschlange (Steuerelemente verfolgen die Maus in einer eigenen Schleife bis dahin),
    /// dann Drücken über das Fenster
    func click(at p: NSPoint, modifiers: NSEvent.ModifierFlags = [], count: Int = 1) {
        NSApp.postEvent(mouse(.leftMouseUp, p, modifiers, clicks: count), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, p, modifiers, clicks: count))
        spin(0.05)
    }

    func doubleClick(at p: NSPoint) {
        click(at: p, count: 1)
        click(at: p, count: 2)
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
    func drag(from a: NSPoint, to b: NSPoint, modifiers: NSEvent.ModifierFlags = [], steps: Int = 6) {
        for i in 1...max(1, steps) {
            let f = CGFloat(i) / CGFloat(max(1, steps))
            NSApp.postEvent(mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), modifiers), atStart: false)
        }
        NSApp.postEvent(mouse(.leftMouseUp, b, modifiers), atStart: false)
        window.sendEvent(mouse(.leftMouseDown, a, modifiers))
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
        if let out = ProcessInfo.processInfo.environment["MIX741_UITEST_DAWSHOT"], let v = u.window.contentView?.superview, let layer = v.layer {
            // Bild des Fensters mit Streifen (zum Ansehen), Zeiger der DAW läuft 1 s
            u.spin(1)
            let w = Int(v.bounds.width * 2), h = Int(v.bounds.height * 2)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: 2, y: 2)
                if v.isFlipped { ctx.translateBy(x: 0, y: v.bounds.height); ctx.scaleBy(x: 1, y: -1) }
                layer.render(in: ctx)
                if let img = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: out))
                    log("daw: bild \(out)")
                }
            }
        }
        send(["v": 1, "t": "bye"])
        u.spin(3) { u.named("A daw") == nil }
        check(u.named("A daw") == nil && bridge.clips.isEmpty, "Streifen bleibt nach dem Abmelden")
        log(String(format: "daw: streifen %.0f × %.0f pt, grid %.2f bpm übernommen + rückgängig", u.frame(strip).width, u.frame(strip).height, bpm))
    }
}
