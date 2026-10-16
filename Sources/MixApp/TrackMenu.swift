import AppKit
import MixCore
import MixEngine

/// Eintrag eines Track-Menüs ohne AppKit (Eintragsliste testbar); `make()` baut den NSMenuItem
@MainActor
struct TrackMenuItem {
    enum Kind {
        case action(() -> Void)
        case submenu([TrackMenuItem])
        case label
        case separator
    }

    var title: String
    var kind: Kind
    var enabled = true
    var checked = false
    var key = ""
    var modifiers: NSEvent.ModifierFlags = .command

    static let separator = TrackMenuItem(title: "", kind: .separator)

    static func action(_ title: String, enabled: Bool = true, checked: Bool = false, _ run: @escaping () -> Void) -> TrackMenuItem {
        TrackMenuItem(title: title, kind: .action(run), enabled: enabled, checked: checked)
    }

    static func label(_ title: String) -> TrackMenuItem { TrackMenuItem(title: title, kind: .label, enabled: false) }

    static func submenu(_ title: String, enabled: Bool = true, _ items: [TrackMenuItem]) -> TrackMenuItem {
        TrackMenuItem(title: title, kind: .submenu(items), enabled: enabled)
    }

    /// Kurzform für Tests: Trenner „—“, Untermenü „Titel ▸“, ausgegraut „(Titel)“
    var outline: String {
        switch kind {
        case .separator: "—"
        case .submenu: enabled ? title + " ▸" : "(" + title + " ▸)"
        case .label: title
        case .action: enabled ? title : "(" + title + ")"
        }
    }

    func make() -> NSMenuItem {
        switch kind {
        case .separator:
            return .separator()
        case let .action(run):
            let i = ActionItem(title, key: key, run)
            if !key.isEmpty { i.keyEquivalentModifierMask = modifiers }
            i.isEnabled = enabled
            i.state = checked ? .on : .off
            return i
        case .label:
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.isEnabled = false
            return i
        case let .submenu(items):
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.submenu = items.menu()
            i.isEnabled = enabled
            return i
        }
    }
}

extension Array where Element == TrackMenuItem {
    @MainActor func menu() -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        for i in self { m.addItem(i.make()) }
        return m
    }

    @MainActor var outline: [String] { map(\.outline) }
}

/// Track-Menü für Browser-Tabelle und Deck: Einträge aus Fakten (was geht) und Aktionen (was passiert).
/// Gemeinsam: Analyse und Rip-Prüfung, Preparation und Playlists, Im Finder zeigen
@MainActor
enum TrackMenu {
    /// Aktionen; Standard: nichts (Tests)
    struct Actions {
        var load: (Int) -> Void = { _ in }
        var edit: () -> Void = {}
        var revertEdits: () -> Void = {}
        var analyze: (Bool) -> Void = { _ in }
        var discardAnalysis: () -> Void = {}
        var overview: () -> Void = {}
        var appendPreparation: () -> Void = {}
        var removePreparation: () -> Void = {}
        var addToPlaylist: (UUID) -> Void = { _ in }
        var newPlaylist: () -> Void = {}
        var removeFromPlaylist: () -> Void = {}
        var makeReady: () -> Void = {}
        var preview: () -> Void = {}
        var finder: () -> Void = {}
        var resetPlayed: () -> Void = {}
        // Deck
        var loadTrack: () -> Void = {}
        var reveal: () -> Void = {}
        var copy: (Int) -> Void = { _ in }
        var dawGrid: () -> Void = {}
        var eject: () -> Void = {}
        var rate: (Int) -> Void = { _ in }
        // Kopieren, Suche, Auswahl (Browser und Deck)
        var copyArtistTitle: () -> Void = {}
        var copyPath: () -> Void = {}
        var search: (String) -> Void = { _ in }
        var selectAll: () -> Void = {}
    }

    /// „Artist – Titel“ ohne fehlende Teile
    static func artistTitle(_ t: Track) -> String { [t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " – ") }

    /// Text in die Zwischenablage
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Untermenü „Bewertung“: aktuelle Stufe abgehakt (nil bei mehreren Tracks)
    static func rating(_ current: Int?, enabled: Bool = true, _ a: Actions) -> TrackMenuItem {
        let stars = (0...5).map { n in
            TrackMenuItem.action(n == 0 ? String(localized: "Keine") : String(repeating: "★", count: n), checked: current == n) { a.rate(n) }
        }
        return .submenu(String(localized: "Bewertung"), enabled: enabled, stars)
    }

    // MARK: Gemeinsame Teile

    /// Analysieren, Neu analysieren, (Analyse verwerfen), Rip prüfen + Befunde
    static func analysis(discard: Bool, rip: [TrackMenuItem], _ a: Actions) -> [TrackMenuItem] {
        var m: [TrackMenuItem] = [.action(String(localized: "Analysieren")) { a.analyze(false) },
                                  .action(String(localized: "Neu analysieren")) { a.analyze(true) }]
        if discard { m.append(.action(String(localized: "Analyse verwerfen")) { a.discardAnalysis() }) }
        return m + rip
    }

    /// Zur Playlist hinzufügen ▸: eigene Playlists mit Ordnerpfad, neue Playlist mit der Auswahl
    static func playlists(_ items: [PlaylistItem], enabled: Bool = true, _ a: Actions) -> TrackMenuItem {
        var sub: [TrackMenuItem] = []
        func walk(_ items: [PlaylistItem], _ depth: Int) {
            for it in items {
                let indent = String(repeating: "   ", count: depth)
                switch it.kind {
                case .folder:
                    sub.append(.label(indent + OwnGlyph.folder + " " + it.name))
                    walk(it.children, depth + 1)
                case .playlist:
                    let id = it.id
                    sub.append(.action(indent + OwnGlyph.playlist + " " + it.name) { a.addToPlaylist(id) })
                case .smartlist: break
                }
            }
        }
        walk(items, 0)
        if !sub.isEmpty { sub.append(.separator) }
        sub.append(.action(String(localized: "Neue Playlist mit der Auswahl")) { a.newPlaylist() })
        return .submenu(String(localized: "Zur Playlist hinzufügen"), enabled: enabled, sub)
    }

    // MARK: Browser-Tabelle

    struct BrowserFacts {
        var hasEdits = false
        var hasAnalysis = false
        var preparation = false
        var ownPlaylist = false
        var cloud = false
        var playlists: [PlaylistItem] = []
        /// Artist und Label des ersten Tracks der Auswahl (Suche)
        var artist = ""
        var label = ""
        /// Bewertung des einzelnen Tracks; nil bei mehreren
        var rating: Int?
    }

    /// Rechtsklick in der Tabelle (Auswahl oder Zeile)
    static func browserItems(_ f: BrowserFacts, rip: [TrackMenuItem], _ a: Actions) -> [TrackMenuItem] {
        var m: [TrackMenuItem] = (0..<4).map { n in .action(String(localized: "In Deck \(["A", "B", "C", "D"][n]) laden")) { a.load(n) } }
        m.append(.separator)
        var edit = TrackMenuItem.action(String(localized: "Bearbeiten …")) { a.edit() }
        edit.key = "e"
        m.append(edit)
        if f.hasEdits { m.append(.action(String(localized: "Eigene Änderungen verwerfen")) { a.revertEdits() }) }
        m.append(.separator)
        m.append(rating(f.rating, a))
        m.append(.separator)
        m += analysis(discard: f.hasAnalysis, rip: rip, a)
        m.append(.separator)
        m.append(.action(String(localized: "An Preparation anhängen")) { a.appendPreparation() })
        if f.preparation { m.append(.action(String(localized: "Aus Preparation entfernen")) { a.removePreparation() }) }
        m.append(playlists(f.playlists, a))
        if f.ownPlaylist {
            var rm = TrackMenuItem.action(String(localized: "Aus Playlist entfernen")) { a.removeFromPlaylist() }
            rm.key = "\u{8}"
            rm.modifiers = []
            m.append(rm)
        }
        m.append(.separator)
        if f.cloud { m.append(.action(String(localized: "Bereitmachen (herunterladen)")) { a.makeReady() }) }
        m.append(.action(String(localized: "Vorhören")) { a.preview() })
        m.append(.action(String(localized: "Im Finder zeigen")) { a.finder() })
        m.append(.action(String(localized: "Artist – Titel kopieren")) { a.copyArtistTitle() })
        m.append(.action(String(localized: "Pfad kopieren")) { a.copyPath() })
        m.append(.action(String(localized: "Nach Artist suchen"), enabled: !f.artist.isEmpty) { a.search(f.artist) })
        m.append(.action(String(localized: "Nach Label suchen"), enabled: !f.label.isEmpty) { a.search(f.label) })
        m.append(.action(String(localized: "Alle auswählen")) { a.selectAll() })
        m.append(.separator)
        m.append(.action(String(localized: "Reset Played State")) { a.resetPlayed() })
        return m
    }

    // MARK: Deck

    struct DeckFacts {
        var deck = 0
        /// angezeigte Decks (Ziele für „Auf Deck … kopieren“)
        var decks = 2
        var hasTrack = false
        /// lädt oder zeigt einen Ladefehler (Auswerfen leert auch das)
        var busy = false
        var playing = false
        /// im aktiven Bereich zu zeigen (steht dort oder in der Collection)
        var revealable = false
        /// in der Library (Preparation, Playlists)
        var inLibrary = false
        /// in der Collection (Bewertung)
        var rateable = false
        var rating = 0
        var hasAnalysis = false
        /// DAW-Clip am Deck: Name, Grid übernehmbar
        var daw: (name: String, usable: Bool)?
        var playlists: [PlaylistItem] = []
    }

    /// Rechtsklick auf die Deckfläche: Deck-Einträge oben, dann die gemeinsamen
    static func deckItems(_ f: DeckFacts, rip: [TrackMenuItem], _ a: Actions) -> [TrackMenuItem] {
        let canEject = (f.hasTrack || f.busy) && !f.playing
        let eject = TrackMenuItem.action(f.playing ? String(localized: "Auswerfen (Deck spielt)") : String(localized: "Auswerfen"),
                                         enabled: canEject) { a.eject() }
        guard f.hasTrack else {
            return [.action(String(localized: "Track laden …")) { a.loadTrack() },
                    .separator,
                    .action(String(localized: "Track bearbeiten …"), enabled: false) {},
                    .action(String(localized: "Im Browser zeigen"), enabled: false) {},
                    .action(String(localized: "Im Finder zeigen"), enabled: false) {},
                    eject]
        }
        var m: [TrackMenuItem] = [.action(String(localized: "Track bearbeiten …")) { a.edit() },
                                  .action(String(localized: "Im Browser zeigen"), enabled: f.revealable) { a.reveal() },
                                  .action(String(localized: "Im Finder zeigen")) { a.finder() },
                                  .action(String(localized: "Pfad kopieren")) { a.copyPath() },
                                  .action(String(localized: "Artist – Titel kopieren")) { a.copyArtistTitle() },
                                  .action(String(localized: "Vorhören")) { a.preview() }]
        for t in 0..<max(f.decks, f.deck + 1) where t != f.deck {
            m.append(.action(String(localized: "Auf Deck \(deckLetters[t]) kopieren")) { a.copy(t) })
        }
        if let c = f.daw {
            m.append(.action(String(localized: "Grid des DAW-Clips übernehmen (\(c.name))"), enabled: c.usable) { a.dawGrid() })
        }
        m.append(eject)
        m.append(.separator)
        m.append(.action(String(localized: "An Preparation anhängen"), enabled: f.inLibrary) { a.appendPreparation() })
        m.append(playlists(f.playlists, enabled: f.inLibrary, a))
        m.append(.separator)
        m += analysis(discard: f.hasAnalysis, rip: [], a)
        m.append(.action(String(localized: "Vorschau berechnen")) { a.overview() })
        m += rip
        m.append(.separator)
        m.append(rating(f.rating, enabled: f.rateable, a))
        return m
    }

    /// Menü für Deck `d` aus dem aktuellen Stand
    static func deckMenu(_ d: Int, mix: MixModel, store: LibraryStore, browser: BrowserState) -> NSMenu {
        let s = mix.deck(d)
        var f = DeckFacts(deck: d, decks: mix.prefs.ui.deckCount, hasTrack: s.track != nil && !s.loading,
                          busy: s.loading || s.error != nil, playing: s.playing || s.cueHeld)
        var a = Actions()
        a.loadTrack = { focusBrowser(deck: d, mix: mix, browser: browser) }
        a.eject = { mix.eject(d) }
        var rip: [TrackMenuItem] = []
        if let t = s.track, !s.loading {
            let key = t.key
            let lib = store.track(key)
            let pane = browser.activePane
            f.revealable = store.byKey[key] != nil || pane.shown.contains { $0.key == key }
            f.inLibrary = lib != nil
            f.rateable = store.byKey[key] != nil
            f.rating = lib?.rating ?? t.rating
            f.hasAnalysis = store.hasAnalysis([key])
            if let c = DAWBridgeModel.shared.clip(deck: d) { f.daw = (c.trackName.isEmpty ? c.name : c.trackName, c.warping && c.markers.count >= 2) }
            f.playlists = store.playlists.items
            let tracks = { [lib ?? t] }
            rip = RipChecks.shared.menuItems(tracks: tracks, single: lib ?? t)
            a.edit = {
                let rows = pane.shown.contains(where: { $0.key == key }) ? pane.shown : [lib ?? t]
                pane.openEditor([key], rows: rows, store: store)
            }
            a.reveal = { reveal(key, browser: browser, mix: mix) }
            a.finder = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.path)]) }
            a.copy = { mix.instantDouble(from: d, to: $0) }
            a.dawGrid = { DAWBridgeModel.shared.applyGrid(deck: d, mix: mix) }
            a.appendPreparation = { store.appendToPreparation([key]) }
            a.addToPlaylist = { store.addToPlaylist([key], $0) }
            a.newPlaylist = {
                let it = store.addOwn(.playlist, into: nil, tracks: [key])
                pane.source = .own(OwnRef(it))
            }
            a.analyze = { Analyses.shared.enqueue(tracks(), refresh: $0) }
            a.discardAnalysis = { store.discardAnalysis([key]) }
            a.overview = { Overviews.shared.enqueue(tracks()) }
            a.rate = { store.applyEdits([key: [.rating: String($0)]], writeBack: mix.prefs.ui.writeCollection) }
            a.preview = { mix.preview(t) }
            a.copyArtistTitle = { TrackMenu.copy(TrackMenu.artistTitle(t)) }
            a.copyPath = { TrackMenu.copy(t.path) }
        }
        return deckItems(f, rip: rip, a).menu()
    }

    /// Track im aktiven Bereich wählen und hinscrollen; steht er dort nicht: TRACK COLLECTION, Suche und Filter leer
    static func reveal(_ key: String, browser: BrowserState, mix: MixModel) {
        let pane = browser.activePane
        if !pane.shown.contains(where: { $0.key == key }) {
            pane.source = .collection
            pane.search = ""
            pane.roles = []
            pane.tags = []
            pane.excludedTags = []
            pane.ripOnly = false
            pane.matching = false
            pane.localOnly = false
            if mix.prefs.ui.hidePlayedTracks, browser.history?.played.contains(key) == true {
                mix.prefs.ui.hidePlayedTracks = false
                StatusCenter.post(.info, String(localized: "UNGESPIELT aus: der Track ist gespielt"), key: "reveal")
            }
        }
        pane.selection = [key]
        browser.activePaneID = pane.id
        // die Liste kommt nach dem Quellwechsel erst im nächsten Durchlauf (große Listen im Hintergrund): Anfrage wiederholen
        for delay in [0.0, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                browser.scrollRequest = nil
                DispatchQueue.main.async { browser.scrollRequest = (pane.id, key) }
            }
        }
    }

    /// leeres Deck: Fokus-Deck setzen, Tabelle des aktiven Bereichs bekommt den Tastatur-Fokus
    static func focusBrowser(deck d: Int, mix: MixModel, browser: BrowserState) {
        mix.focusedDeck = d
        let pane = browser.activePane
        guard let win = MainWindow.window ?? NSApp.keyWindow, let root = win.contentView else { return }
        func find(_ v: NSView) -> TrackNSTable? {
            if let t = v as? TrackNSTable, (t.delegate as? TrackTableController)?.model === pane { return t }
            for s in v.subviews { if let t = find(s) { return t } }
            return nil
        }
        if let tv = find(root) { win.makeFirstResponder(tv) }
    }
}

/// Browser-Tabelle: Fakten und Aktionen für das Track-Menü
extension TrackTableController {
    /// Kontextmenü (TrackMenu): was für die Auswahl geht
    func browserFacts(_ ids: Set<String>) -> TrackMenu.BrowserFacts {
        guard let store, let model else { return TrackMenu.BrowserFacts() }
        var preparation = false
        if case .preparation = model.source { preparation = true }
        let first = ids.lazy.compactMap { store.track($0) }.first
        return TrackMenu.BrowserFacts(hasEdits: store.hasEdits(ids), hasAnalysis: store.hasAnalysis(ids), preparation: preparation,
                                      ownPlaylist: model.ownPlaylistID != nil, cloud: CloudLibrary.shared.hasCloudTracks,
                                      playlists: store.playlists.items, artist: first?.artist ?? "", label: first?.label ?? "",
                                      rating: ids.count == 1 ? first?.rating : nil)
    }

    /// Kontextmenü (TrackMenu): Aktionen für die Auswahl
    func browserActions(_ ids: Set<String>, rows: [Track], tracks: @escaping () -> [Track], store: LibraryStore, model: BrowserPaneModel,
                        mix: MixModel, history: HistoryStore) -> TrackMenu.Actions {
        let ordered = rows.map(\.key).filter { ids.contains($0) }
        let keys = ordered.isEmpty ? Array(ids) : ordered
        var a = TrackMenu.Actions()
        a.load = { [weak mix] n in if let id = ids.first, let t = store.track(id) { mix?.load(t, deck: n) } }
        a.edit = { [weak model] in model?.openEditor(ids, rows: rows, store: store) }
        a.revertEdits = { store.revertEdits(Array(ids)) }
        a.analyze = { Analyses.shared.enqueue(tracks(), refresh: $0) }
        a.discardAnalysis = { store.discardAnalysis(Array(ids)) }
        a.appendPreparation = { store.appendToPreparation(ids) }
        a.removePreparation = { store.editPreparation(String(localized: "Aus Preparation entfernen")) { $0.removeAll { ids.contains($0) } } }
        a.addToPlaylist = { store.addToPlaylist(keys, $0) }
        a.newPlaylist = {
            let it = store.addOwn(.playlist, into: nil, tracks: keys)
            model.source = .own(OwnRef(it))
        }
        if let id = model.ownPlaylistID { a.removeFromPlaylist = { store.removeFromPlaylist(ids, id) } }
        a.makeReady = { CloudLibrary.shared.makeReady(tracks(), label: String(localized: "Auswahl")) }
        a.preview = { [weak mix] in if let id = ids.first, let t = store.track(id) { mix?.preview(t) } }
        a.finder = { NSWorkspace.shared.activateFileViewerSelecting(tracks().map { URL(fileURLWithPath: $0.path) }) }
        a.resetPlayed = { [weak history] in history?.resetPlayed(keys: Set(keys)) }   // nur die gewählten Tracks
        a.copyArtistTitle = { TrackMenu.copy(tracks().map(TrackMenu.artistTitle).joined(separator: "\n")) }
        a.copyPath = { TrackMenu.copy(tracks().map(\.path).joined(separator: "\n")) }
        a.search = { [weak model] text in model?.search = text }
        a.selectAll = { [weak model] in model?.selection = Set(rows.map(\.id)) }
        a.rate = { [weak mix] n in
            guard let mix else { return }
            store.applyEdits(Dictionary(uniqueKeysWithValues: keys.map { ($0, [TrackField.rating: String(n)]) }), writeBack: mix.prefs.ui.writeCollection)
        }
        return a
    }
}
