import Foundation
import LibraryCloud
import MixCore
import MixEngine

/// Sitzung, die einen Neustart überlebt: Deck-Einstellungen, FX, Clock, Browser
struct Session: Codable {
    struct Deck: Codable {
        var keylock: Bool?, tempoRange: Double?, loopSize: Double?, jumpSize: Double?
        var gainDb: Double?, eqLow: Double?, eqMid: Double?, eqHigh: Double?, filter: Double?, fader: Double?
        var xf: XFAssign?, fxAssign: [Bool]?
    }
    struct Pane: Codable {
        var source: String?, sort: String?, ascending: Bool?, roles: [String]?, tags: [String]?, showTree: Bool?
        /// MUSIC FOLDERS: Unterordner einbeziehen
        var subfolders: Bool?
        /// Favoritenleiste (6 Plätze, leer = null)
        var favorites: [BrowserFavorite?]?
        /// ausgeschlossene Tags (⌥-Klick)
        var excludedTags: [String]?
    }
    var decks: [Deck]?
    var fx: [FXUnitState]?
    /// Master-Bus (Plugin-Kette nach der Summe)
    var masterFX: MasterFXState?
    var clockBPM: Double?, clockMaster: Bool?, metronome: Bool?, metronomeVolume: Double?, linkEnabled: Bool?, semiSync: Bool?
    var crossfader: Double?, masterVolume: Double?
    var panes: [Pane]?
    var maximized: Bool?

    static let url = HistoryStore.baseDir.appendingPathComponent("session.json")

    /// Selbsttest oder Messung (MIX741_BENCH): nichts von Christians Einstellungen, Sitzung, History anfassen
    static let isSelfTest = ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" || ToggleBench.requested

    static func load() -> Session? {
        guard !isSelfTest, let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }

    @MainActor private static var lastSaved: Data?

    @MainActor static func saveIfChanged(mix: MixModel, browser: BrowserState) {
        guard !isSelfTest, browser.store?.preparationArchived == true,   // erst speichern, wenn alles wiederhergestellt ist
              let d = try? JSONEncoder().encode(Session(mix: mix, browser: browser)), d != lastSaved else { return }
        if lastSaved == nil, (try? Data(contentsOf: url)) == d { lastSaved = d; return }
        lastSaved = d
        DispatchQueue.global(qos: .utility).async { try? d.write(to: url, options: .atomic) }
    }

    /// beim Beenden: sofort und synchron schreiben
    @MainActor static func saveNow(mix: MixModel, browser: BrowserState) {
        guard !isSelfTest, let d = try? JSONEncoder().encode(Session(mix: mix, browser: browser)) else { return }
        lastSaved = d
        try? d.write(to: url, options: .atomic)
    }

    @MainActor init(mix: MixModel, browser: BrowserState) {
        let s = mix.state
        decks = s.decks.map {
            Deck(keylock: $0.keylock, tempoRange: $0.tempoRange, loopSize: $0.loopSize, jumpSize: $0.jumpSize,
                 gainDb: $0.gainDb, eqLow: $0.eqLow, eqMid: $0.eqMid, eqHigh: $0.eqHigh, filter: $0.filter, fader: $0.fader,
                 xf: $0.xf, fxAssign: $0.fxAssign)
        }
        fx = s.fx
        masterFX = s.masterFX
        clockBPM = s.clockBPM; clockMaster = s.clockMaster; metronome = s.metronome; semiSync = s.semiSync
        metronomeVolume = s.metronomeVolume; linkEnabled = s.linkEnabled
        crossfader = s.crossfader; masterVolume = s.masterVolume
        panes = [browser.paneA, browser.paneB].map { p in
            let c = p.sortOrder.first
            return Pane(source: Session.sourceID(p.source), sort: c.flatMap { Session.sortName($0) },
                        ascending: c.map { $0.order == .forward }, roles: p.roles.map(\.rawValue),
                        tags: p.tags.sorted(), showTree: p.showTree, subfolders: p.subfolders,
                        favorites: p.favorites.contains { $0 != nil } ? p.favorites : nil,
                        excludedTags: p.excludedTags.isEmpty ? nil : p.excludedTags.sorted())
        }
        maximized = browser.maximized
    }

    /// Mixer, FX und Clock sofort übernehmen
    @MainActor func applyEngine(to mix: MixModel) {
        mix.core.restore { s in
            for (i, d) in (decks ?? []).enumerated() where i < s.decks.count {
                if let v = d.keylock { s.decks[i].keylock = v }
                if let v = d.tempoRange { s.decks[i].tempoRange = v }
                if let v = d.loopSize { s.decks[i].loopSize = v }
                if let v = d.jumpSize { s.decks[i].jumpSize = v }
                if let v = d.gainDb { s.decks[i].gainDb = v }
                if let v = d.eqLow { s.decks[i].eqLow = v }
                if let v = d.eqMid { s.decks[i].eqMid = v }
                if let v = d.eqHigh { s.decks[i].eqHigh = v }
                if let v = d.filter { s.decks[i].filter = v }
                if let v = d.fader { s.decks[i].fader = v }
                if let v = d.xf { s.decks[i].xf = v }
                if let v = d.fxAssign { for u in 0..<min(v.count, s.decks[i].fxAssign.count) { s.decks[i].fxAssign[u] = v[u] } }
            }
            if let v = fx { for u in 0..<min(v.count, s.fx.count) { s.fx[u] = v[u] } }
            if let v = masterFX { s.masterFX = v }
            if let v = clockBPM { s.clockBPM = v }
            if let v = clockMaster { s.clockMaster = v }
            if let v = semiSync { s.semiSync = v }
            if let v = metronome { s.metronome = v }
            if let v = metronomeVolume { s.metronomeVolume = v }
            if let v = linkEnabled { s.linkEnabled = v }
            if let v = crossfader { s.crossfader = v }
            if let v = masterVolume { s.masterVolume = v }
        }
        mix.pull()
    }

    /// Browser-Quellen brauchen die geladene Collection (Playlists, Smartlists)
    @MainActor func applyBrowser(_ browser: BrowserState, store: LibraryStore, history: HistoryStore) {
        if let m = maximized { browser.maximized = m }
        for (i, p) in (panes ?? []).enumerated() where i < 2 {
            let pane = browser.pane(i)
            if let id = p.source, let src = Session.source(id, store: store) { pane.source = src }
            if let n = p.sort, let c = Session.comparator(n, ascending: p.ascending ?? true) { pane.sortOrder = [c] }
            if let r = p.roles { pane.roles = Set(r.compactMap(RoleFilter.init(rawValue:))) }
            if let t = p.tags { pane.tags = Set(t) }
            if let t = p.excludedTags { pane.excludedTags = Set(t) }
            if let v = p.showTree { pane.showTree = v }
            if let v = p.subfolders { pane.subfolders = v }
            if let f = p.favorites { pane.favorites = BrowserFavorite.normalized(f) }
        }
    }

    // MARK: Quellen als Text

    static func sourceID(_ s: BrowserSource) -> String? {
        switch s {
        case .collection: "collection"
        case .preparation: "preparation"
        case .running: "running"
        case .cuts: "cuts"
        case .toolLoops: "toolloops"
        case .daw: "daw"
        case .historyLive: "history"
        case .custom(let c): "custom:\(c.id.uuidString)"
        case .node(let n): "node:\(n.name)"
        case .folder(let p): "folder:" + p
        case .history, .prepArchive: nil
        }
    }

    @MainActor static func source(_ id: String, store: LibraryStore) -> BrowserSource? {
        switch id {
        case "collection": return .collection
        case "preparation": return .preparation
        case "running": return .running
        case "cuts": return .cuts
        case "toolloops": return .toolLoops
        case "daw": return .daw
        case "history": return .historyLive
        default: break
        }
        if id.hasPrefix("custom:") {
            let u = String(id.dropFirst(7))
            return store.customSmartlists.first { $0.id.uuidString == u }.map { .custom($0) }
        }
        if id.hasPrefix("folder:") {
            // ohne Materialisieren (Hauptthread, Ordner oft im Cloud-Laufwerk): ein noch nicht geladener Ordner
            // meldet EDEADLK statt auf den Anbieter zu warten – er ist da, die Liste liest MusicFolderStore im Hintergrund
            let p = String(id.dropFirst(7))
            let folder = SystemCloudFileSystem.withoutMaterializing {
                var st = stat()
                return stat(p, &st) == 0 ? st.st_mode & S_IFMT == S_IFDIR : errno == EDEADLK
            }
            return folder ? .folder(p) : nil
        }
        if id.hasPrefix("node:") {
            let name = String(id.dropFirst(5))
            func find(_ n: PlaylistNode) -> PlaylistNode? {
                if n.kind != .folder, n.name == name { return n }
                for c in n.children { if let f = find(c) { return f } }
                return nil
            }
            return find(store.root).map { .node($0) }
        }
        return nil
    }

    // MARK: Sortierung als Text

    static func sortName(_ c: KeyPathComparator<Track>) -> String? {
        let all: [(String, PartialKeyPath<Track>)] = [
            ("artist", \Track.artist), ("title", \Track.title), ("bpm", \Track.bpm), ("key", \Track.openKey),
            ("time", \Track.duration), ("comment", \Track.comment), ("comment2", \Track.comment2),
            ("label", \Track.label), ("import", \Track.importSort), ("plays", \Track.playCount), ("color", \Track.color),
            ("harmony", \Track.harmonySort),
        ]
        return all.first { $0.1 == c.keyPath }?.0
    }

    static func comparator(_ name: String, ascending: Bool) -> KeyPathComparator<Track>? {
        let o: SortOrder = ascending ? .forward : .reverse
        switch name {
        case "artist": return KeyPathComparator(\Track.artist, order: o)
        case "title": return KeyPathComparator(\Track.title, order: o)
        case "bpm": return KeyPathComparator(\Track.bpm, order: o)
        case "key": return KeyPathComparator(\Track.openKey, order: o)
        case "time": return KeyPathComparator(\Track.duration, order: o)
        case "comment": return KeyPathComparator(\Track.comment, order: o)
        case "comment2": return KeyPathComparator(\Track.comment2, order: o)
        case "label": return KeyPathComparator(\Track.label, order: o)
        case "import": return KeyPathComparator(\Track.importSort, order: o)
        case "plays": return KeyPathComparator(\Track.playCount, order: o)
        case "color": return KeyPathComparator(\Track.color, order: o)
        case "harmony": return KeyPathComparator(\Track.harmonySort, order: o)
        default: return nil
        }
    }
}
