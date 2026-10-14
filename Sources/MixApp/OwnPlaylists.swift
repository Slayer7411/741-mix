import AppKit
import Foundation
import MixCore
import LibraryCloud

/// Quelle „eigener Eintrag“: gleich über die ID (Name nur für den Titel, nach dem Umbenennen nachgezogen)
struct OwnRef: Hashable, Sendable {
    let id: UUID
    var name: String
    var kind: PlaylistItem.Kind

    init(_ i: PlaylistItem) { id = i.id; name = i.name; kind = i.kind }

    static func == (a: OwnRef, b: OwnRef) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Baum + Umgebung für das Vorsortieren im Hintergrund
struct OwnSnapshot: Sendable {
    var tree: PlaylistTree
    var context: SmartContext
}

/// `playlists.json` im MINOS-741-Ordner (Selbsttest: eigener Temp-Ordner). Erster Start ohne Datei: die eigenen
/// Smartlists der früheren Liste (UserDefaults `smartlists.custom`) wandern hinein, der alte Eintrag bleibt stehen.
/// Schreiben im Hintergrund, atomar, in Reihenfolge
@MainActor
enum PlaylistFile {
    static var url: URL {
        Session.isSelfTest ? selfTestDir.appendingPathComponent("playlists.json") : HistoryStore.baseDir.appendingPathComponent("playlists.json")
    }
    static let selfTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-selftest-playlists-\(getpid())", isDirectory: true)
    nonisolated private static let queue = DispatchQueue(label: "minos741.playlists", qos: .utility)
    /// Meldung beim Laden (unlesbare Datei beiseitegelegt)
    static var loadNote: String?

    static func load() -> PlaylistTree {
        load(url: url, legacy: Session.isSelfTest ? [] : CustomSmartlist.load().map { ($0.id, $0.name, $0.query) })
    }

    /// Datei lesen; fehlt sie: aus den alten Smartlists anlegen. Unlesbar: beiseitelegen (`playlists-unlesbar-…`), leer
    static func load(url: URL, legacy: [(id: UUID, name: String, query: String)]) -> PlaylistTree {
        if let d = try? Data(contentsOf: url) {
            if let t = try? PlaylistTree.decode(d) { return t }
            let stamp = Int(Date().timeIntervalSince1970)
            let aside = url.deletingLastPathComponent().appendingPathComponent("playlists-unlesbar-\(stamp).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            loadNote = String(localized: "playlists.json nicht lesbar – beiseitegelegt als \(aside.lastPathComponent)")
            if let note = loadNote { DispatchQueue.main.async { StatusCenter.post(.warning, note, detail: aside.path, key: "playlists") } }
            return PlaylistTree()
        }
        let t = PlaylistTree.migrated(legacy: legacy)
        if !legacy.isEmpty { write(t, to: url) }
        return t
    }

    static func save(_ t: PlaylistTree) { write(t, to: url) }

    static func write(_ t: PlaylistTree, to url: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try t.encoded().write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async { StatusCenter.post(.error, String(localized: "Playlists nicht gespeichert: \(error.localizedDescription)"), detail: url.path, key: "playlists") }
            }
        }
    }

    /// wartet, bis alles geschrieben ist (Selbsttest, Beenden)
    nonisolated static func flush() { queue.sync {} }

    static func removeSelfTestDir() { try? FileManager.default.removeItem(at: selfTestDir) }
}

extension LibraryStore {
    /// Ordner der eigenen Playlists in der Collection-Datei: `$ROOT/MINOS-741/Playlists`
    nonisolated static let ownPlaylistsFolder = "Playlists"

    /// nach jeder Änderung des Baums: Zähler je Eintrag, Titel der Bereiche, speichern, Collection-Datei
    func playlistsChanged(from old: PlaylistTree) {
        guard playlists != old else { return }
        playlistRevision += 1
        let before = Dictionary(old.all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = playlists.all
        for it in now where before[it.id].map({ $0.tracks != it.tracks || $0.rules != it.rules || $0.kind != it.kind }) ?? true {
            ownRevisions[it.id, default: 0] += 1
            ownCache[it.id] = nil
        }
        // Bereiche: umbenannt -> neuer Titel, gelöscht -> Collection
        for pane in [browser?.paneA, browser?.paneB].compactMap({ $0 }) {
            guard case let .own(r) = pane.source else { continue }
            if let it = playlists.item(r.id) {
                if it.name != r.name { pane.source = .own(OwnRef(it)) }
            } else {
                pane.source = .collection
            }
        }
        PlaylistFile.save(playlists)
        let ui = uiPrefs()
        if ui.writeCollection, ui.writePlaylists, old.nmlNodes != playlists.nmlNodes { scheduleWriteBack(after: 10) }
    }

    /// Baum ändern mit Rückgängig
    func editPlaylists(_ label: String, _ f: (inout PlaylistTree) -> Void) {
        let old = playlists
        var new = old
        f(&new)
        guard new != old else { return }
        playlists = new
        UndoStack.shared.record(label, before: old, after: new) { [weak self] b, a, undo in self?.playlists = undo ? b : a }
    }

    func ownRevision(_ r: OwnRef) -> Int {
        let v = ownRevisions[r.id] ?? 0
        guard let it = playlists.item(r.id), it.kind == .smartlist else { return v }
        return v &* 1_000_003 &+ smartStamp(it.rules)
    }

    /// Stand der Umgebung, an der die Regeln hängen (gespielt, Cloud, Trennzeichen)
    func smartStamp(_ r: SmartRules) -> Int {
        var h = Hasher()
        if r.usesPlayed { h.combine(history?.playedRevision ?? 0) }
        if r.usesAvailability { h.combine(CloudLibrary.shared.revision) }
        if r.rules.contains(where: { $0.field == .tag }) { h.combine(browser?.separators() ?? " ") }
        return h.finalize()
    }

    /// Tracks eines eigenen Eintrags: Playlist in ihrer Reihenfolge, Smartlist aus dem Zwischenspeicher, Ordner leer
    func ownTracks(_ id: UUID) -> [Track] {
        guard let it = playlists.item(id) else { return [] }
        switch it.kind {
        case .folder: return []
        case .playlist: return it.tracks.compactMap { track($0) }
        case .smartlist:
            let stamp = smartStamp(it.rules)
            if let hit = ownCache[id], hit.rules == it.rules, hit.stamp == stamp { return hit.tracks }
            let res = it.rules.compile(smartContext(for: it.rules)).apply(tracks)
            ownCache[id] = OwnHit(rules: it.rules, stamp: stamp, tracks: res)
            return res
        }
    }

    /// Tracks unter einem eigenen Eintrag (Ordner: alle darunter, ohne doppelte)
    func ownTracksDeep(_ id: UUID) -> [Track] {
        guard let it = playlists.item(id) else { return [] }
        guard it.kind == .folder else { return ownTracks(id) }
        var seen = Set<String>()
        return PlaylistTree(items: it.children).all.filter { $0.kind != .folder }.flatMap { ownTracks($0.id) }.filter { seen.insert($0.key).inserted }
    }

    /// Umgebung für das Hintergrund-Vorsortieren (ohne Cloud-Zustand; solche Regeln sortiert der Hauptthread)
    func smartContext(background: Bool) -> SmartContext {
        SmartContext(separators: browser?.separators() ?? " ", played: history?.played ?? [])
    }

    /// Umgebung für `rules`: Cloud-Zustand vorab als Tabelle (nur wenn eine Regel ihn braucht), auch im Hintergrund nutzbar
    func smartContext(for rules: SmartRules) -> SmartContext {
        var ctx = SmartContext(separators: browser?.separators() ?? " ", played: rules.usesPlayed ? history?.played ?? [] : [])
        if rules.usesAvailability {
            let cloud = CloudLibrary.shared
            var m: [String: SmartAvailability] = [:]
            m.reserveCapacity(tracks.count)
            for t in tracks {
                switch cloud.peek(t.path) {
                case .local?: m[t.key] = .local
                case .cloud?: m[t.key] = .cloud
                case .missing?: m[t.key] = .missing
                default: break
                }
            }
            let table = m
            ctx.availability = { table[$0.key] ?? ($0.fileExists ? .local : .missing) }
        }
        return ctx
    }

    // MARK: - Anlegen

    /// neuer Eintrag im Ordner `parent` (nil = oben), am Ende; Ergebnis = der Eintrag
    @discardableResult
    func addOwn(_ kind: PlaylistItem.Kind, into parent: UUID?, name: String? = nil, tracks keys: [String] = [],
                rules: SmartRules = SmartRules()) -> PlaylistItem {
        let base = name ?? (kind == .folder ? String(localized: "Neuer Ordner") : kind == .playlist ? String(localized: "Neue Playlist") : String(localized: "Neue Smartlist"))
        var it = PlaylistItem(name: playlists.uniqueName(base, in: parent), kind: kind, rules: rules)
        if kind == .playlist { var seen = Set<String>(); it.tracks = keys.filter { seen.insert($0).inserted } }
        let label = kind == .folder ? String(localized: "Neuer Ordner") : kind == .playlist ? String(localized: "Neue Playlist") : String(localized: "Neue Smartlist")
        editPlaylists(label) { $0.insert(it, into: parent) }
        return it
    }

    /// Tracks an eine eigene Playlist (Rückgängig), Meldung in der Statusleiste
    func addToPlaylist(_ keys: [String], _ id: UUID, at index: Int? = nil) {
        guard let it = playlists.item(id), it.kind == .playlist else { return }
        var n = 0
        editPlaylists(String(localized: "Zur Playlist hinzufügen")) { n = $0.addTracks(keys, to: id, at: index) }
        StatusCenter.post(.ok, n > 0 ? String(localized: "\(n) Tracks in „\(it.name)“") : String(localized: "Schon in „\(it.name)“"), key: "playlist")
    }

    func removeFromPlaylist(_ keys: Set<String>, _ id: UUID) {
        editPlaylists(String(localized: "Aus Playlist entfernen")) { $0.removeTracks(keys, from: id) }
    }

    // MARK: - Werte für den Smartlist-Editor

    /// Werte eines Felds aus der Collection, häufigste zuerst (Tags: zerlegt aus Kommentar 2)
    func suggestions(for f: SmartField) -> [(value: String, count: Int)] {
        guard f.suggests else { return [] }
        let key = "\(f.rawValue)|\(revision)|\(f == .tag ? browser?.separators() ?? " " : "")"
        if let hit = suggestionCache[key] { return hit }
        var counts: [String: Int] = [:]
        if f == .tag {
            let seps = browser?.separators() ?? " "
            for t in tracks where !t.comment2.isEmpty {
                for tag in BrowserPaneModel.tagIndex.entry(t.comment2, separators: seps).tags { counts[tag, default: 0] += 1 }
            }
        } else if f == .path {
            for t in tracks { counts[(t.path as NSString).deletingLastPathComponent + "/", default: 0] += 1 }
        } else {
            for t in tracks {
                let v = SmartRules.text(t, f).trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { counts[v, default: 0] += 1 }
            }
        }
        var list: [(value: String, count: Int)] = counts.map { (value: $0.key, count: $0.value) }
        list.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.value.localizedStandardCompare(b.value) == .orderedAscending
        }
        if suggestionCache.count > 40 { suggestionCache = [:] }
        suggestionCache[key] = list
        return list
    }
}
