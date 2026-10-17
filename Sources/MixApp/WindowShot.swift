import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SELFTEST=1 MIX741_SHOT=window:<png>): ganzes Hauptfenster mit Titel- und Werkzeugleiste
/// offscreen als PNG (README-Bild). Fenster MIX741_SHOT_SIZE (Standard 1600x1000 pt), Bild MIX741_SHOT_SCALE
/// (Standard 1.25 -> 2000 px breit). 4 Decks mit lokalen Tracks (keine Cloud-Platzhalter): A Master, B Sync + Loop 8,
/// D EDIT mit Schnitt; ohne internen Mixer (Status: extern), Browser nebeneinander. Sprache per `-AppleLanguages '(en)'`.
/// Collection und Einstellungen nur gelesen, Spalten in Standard-Anordnung, Audio stumm auf einem eingebauten Gerät.
@MainActor
enum WindowShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("window:") else { return }
        run(URL(fileURLWithPath: String(spec.dropFirst("window:".count))))
    }

    static func run(_ url: URL) -> Never {
        let env = ProcessInfo.processInfo.environment
        NSApplication.shared.setActivationPolicy(.prohibited)
        SelfTest.enabled = false
        let size = (env["MIX741_SHOT_SIZE"] ?? "1600x1000").split(separator: "x").compactMap { Double($0) }
        let base = NSSize(width: size.first ?? 1600, height: size.dropFirst().first ?? 1000)
        let scale = env["MIX741_SHOT_SCALE"].flatMap(Double.init) ?? 1.25

        // eingebaute Lautsprecher, stumm; Argument-Domäne (-AppleLanguages) bleibt, Spalten in Standard-Anordnung
        let d = E2E.defaults
        let args = d.volatileDomain(forName: UserDefaults.argumentDomain)
            .merging(["columns.Basis": Data(), "columns.Layer": Data()]) { $1 }
        let devs = MixEngine.outputDevices()
        let dev = devs.first { $0.channels == 2 && $0.name.localizedCaseInsensitiveContains("speaker") } ?? devs.first { $0.channels < 8 }
        d.setVolatileDomain(args.merging(["deviceUID": dev?.uid ?? "-", "mixerMode": MixerMode.internalMixer.rawValue,
                                          "sampleRate": 0.0, "bufferSize": 0, "masterVolume": 0.0]) { $1 },
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.setVolatileDomain(args, forName: UserDefaults.argumentDomain)

        // feste Ansicht (Selbsttest speichert nichts)
        mix.prefs.ui.showMixer = false
        let layout = env["MIX741_LAYOUT"] ?? ""
        mix.prefs.ui.deckCount = layout.contains("1deck") ? 1 : layout.contains("2decks") ? 2 : 4
        if env["MIX741_LAYOUT"]?.contains("mixer") == true { mix.prefs.ui.showMixer = true }
        mix.prefs.ui.browserLayout = .sideBySide
        mix.prefs.ui.browserHeight = 330
        mix.prefs.ui.hideTreeWithDecks = false
        mix.prefs.ui.showAllDeckRows()
        // MIX741_SHOT_ROWS=phaseBar,loop: nur diese Deck-Zeilen (Namen wie in DeckRows, `grid` = Grid-Werkzeuge)
        if let rows = env["MIX741_SHOT_ROWS"] {
            let paths: [String: WritableKeyPath<UIPrefs, Bool>] = [
                "info": \.deckRows.info, "comment": \.deckRows.comment, "tags": \.deckRows.tags, "phaseBar": \.deckRows.phaseBar,
                "overview": \.deckRows.overview, "transport": \.deckRows.transport, "hotcues": \.deckRows.hotcues,
                "loop": \.deckRows.loop, "jump": \.deckRows.jump, "tempo": \.deckRows.tempo, "grid": \.showGridTools,
                "groove": \.deckRows.groove, "prepare": \.deckRows.prepare]
            for p in paths.values { mix.prefs.ui[keyPath: p] = false }
            for n in rows.split(separator: ",") { if let p = paths[String(n)] { mix.prefs.ui[keyPath: p] = true } }
        }
        mix.prefs.ui.zoom = 1
        ZoomControl.apply(1)

        let store = LibraryStore(), history = HistoryStore(), browser = BrowserState()
        browser.store = store
        browser.history = history
        browser.separators = { [mix] in mix.prefs.ui.tagSeparators }
        // MIX741_SHOT_PROFILE=<Name>: dieses Ansichts-Profil vor dem Bild anwenden (gespeicherte, sonst Standard-Profile)
        if let name = env["MIX741_SHOT_PROFILE"] {
            let list = mix.prefs.ui.layoutProfiles + LayoutProfile.defaults(from: mix.prefs.ui)
            guard let p = list.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                log("kein Profil \(name): \(list.map(\.name).joined(separator: ", "))"); exit(1)
            }
            LayoutProfiles.apply(p, mix: mix, browser: browser)
            log("Profil \(p.name): \(p.deckCount) Decks, Mixer \(p.showMixer), Browser \(p.browserLayout.rawValue) \(Int(p.browserHeight)) pt")
        }
        store.load()
        spin(120, until: { !store.tracks.isEmpty })
        // nur Dateien mit Inhalt auf der Platte, mit Grid, Key und Tags; je Künstler einer. 4 Decks, 12 Preparation
        var artists = Set<String>()
        let c = Array(store.tracks.filter {
            $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && $0.musicalKey >= 0 && !$0.comment2.isEmpty
                && $0.duration > 240 && $0.fileExists && OverviewPolicy.fileState(path: $0.path) == .local
                && artists.insert($0.artist.lowercased()).inserted
        }.prefix(16))
        guard c.count == 16 else { log("zu wenige lokale Tracks"); exit(1) }
        for (i, t) in c.prefix(4).enumerated() {
            log("\(deckLetters[i]): \(t.artist) – \(t.title) \(t.bpm)")
            mix.load(t, deck: i)
        }
        spin(90, until: { (0..<4).allSatisfy { mix.core.trackAudio($0) != nil } })
        guard (0..<4).allSatisfy({ mix.core.trackAudio($0) != nil }) else { log("Laden zu langsam"); exit(1) }
        // Positionen auf Beats, B Loop 8, D EDIT mit Schnitt
        for (i, beat) in [96.0, 160, 64, 128].enumerated() {
            let g = BeatGrid(track: c[i])!
            mix.core.seek(i, seconds: g.time(ofBeat: beat))
        }
        spin(0.5)
        mix.core.toggleMaster(0)
        mix.core.toggleSync(1)
        mix.core.setLoopSize(1, 8)
        mix.core.autoLoop(1, size: 8)
        for i in 0..<4 { mix.setEditing(i, i == 3) }
        let g = BeatGrid(track: c[3])!
        mix.setTrimPoint(3, end: false, g.time(ofBeat: 32))
        mix.setTrimPoint(3, end: true, g.time(ofBeat: g.beatPosition(at: c[3].duration - 30).rounded(.down)))
        // Anzeige wie mit externem Mixer (Routing bleibt intern auf dem eingebauten Gerät)
        mix.mixerMode = .external
        mix.deckPairs = [0, 4, 2, 6]
        mix.engineStatus = "USB Audio · \(mix.routeText) · " + String(format: "%g kHz", mix.engine.outputRate / 1000)
        mix.pull()
        // A: Preparation (nur im Speicher), B: Collection (nur lokale), zuletzt gespielt zuerst
        store.preparation = c.dropFirst(4).map(\.key)
        browser.paneA.source = .preparation
        browser.paneA.sortOrder = []
        browser.paneB.sortOrder = [KeyPathComparator(\Track.lastPlayedSort, order: .reverse)]
        browser.paneB.localOnly = true

        let root = ContentView()
            .environment(store).environment(mix).environment(browser)
            .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let host = NSHostingView(rootView: root)
        host.sceneBridgingOptions = [.toolbars]
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: base),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.toolbarStyle = .unified
        win.title = MixApp.appTitle
        win.contentView = host
        win.setContentSize(base)
        let pump = { mix.pull(); host.layoutSubtreeIfNeeded(); CATransaction.flush() }
        spin(4, step: pump)   // Wellenform-Kacheln, Cloud-Prüfung
        // je erste Zeile gewählt (Cover unter dem Baum), Vorschauen der sichtbaren Zeilen
        var visible: [Track] = []
        for p in [browser.paneA, browser.paneB] {
            let rows = p.rows(from: store, history: history, separators: mix.prefs.ui.tagSeparators)
            if let t = rows.first { p.selection = [t.id] }
            visible += rows.prefix(12).filter { OverviewPolicy.fileState(path: $0.path) == .local }
        }
        Overviews.shared.enqueue(visible)
        spin(0.5, step: pump)
        spin(60, step: pump, until: { Overviews.shared.jobs.isIdle })
        spin(1, step: pump)
        // Meldungen (Laden der Collection) und Aussetzer beim Aufbau nicht im Bild
        for _ in 0..<50 { guard let m = StatusCenter.shared.current else { break }; StatusCenter.shared.dismiss(m) }
        MeterSampler.shared.resetDropouts()
        spin(1, step: pump)
        guard let frame = host.superview, snapshot(frame, scale: scale, to: url) else { log("kein Bild"); exit(1) }
        log("\(url.path) \(Int(frame.bounds.width * scale)) × \(Int(frame.bounds.height * scale)) px")
        exit(0)
    }

    private static func spin(_ s: Double, step: () -> Void = {}, until done: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(s)
        while Date() < end, !done() { step(); RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    /// Fensterrahmen (Titel, Werkzeugleiste, Inhalt) über den Ebenen-Baum rendern
    private static func snapshot(_ v: NSView, scale: CGFloat, to url: URL) -> Bool {
        guard let layer = v.layer else { return false }
        let w = Int(v.bounds.width * scale), h = Int(v.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        if v.isFlipped {
            ctx.translateBy(x: 0, y: v.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage(),
              let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    static func log(_ s: String) {
        print("[window] \(s)")
        fflush(stdout)
    }
}
