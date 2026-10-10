import AppKit
import Observation
import MixCore

/// Hält die geladene Collection; alle Browser-Bereiche lesen daraus.
@MainActor @Observable
final class LibraryStore {
    /// Standard-Collection: neueste `collection.nml` im Benutzerordner der Collection-Software
    nonisolated static let defaultNML: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Native Instruments")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        let found = dirs.filter { $0.lastPathComponent.hasPrefix("Traktor") }
            .map { $0.appendingPathComponent("collection.nml") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedDescending }
        return found.first ?? base.appendingPathComponent("Traktor 3.11.2/collection.nml")
    }()

    /// Collection-Software läuft? Dann nicht in die Collection-Datei schreiben – sie hält die Collection im Speicher
    /// und überschreibt die Datei beim Beenden.
    nonisolated static func collectionSoftwareRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            (app.localizedName ?? "").hasPrefix("Traktor")
                || (app.bundleIdentifier ?? "").localizedCaseInsensitiveContains("traktor")
                || (app.executableURL?.lastPathComponent ?? "").hasPrefix("Traktor")
        }
    }

    var tracks: [Track] = [] { didSet { revision += 1 } }
    /// zählt jede Änderung an Collection/Preparation/Smartlists (für Browser-Zwischenspeicher)
    private(set) var revision = 0
    var root = PlaylistNode(name: "Playlists", kind: .folder)
    /// Tracks, die gerade auf den Decks liegen (A-D) – Quelle RUNNING TRACKS
    var running: [Track] = [] { didSet { runningRevision += 1 } }
    private(set) var runningRevision = 0
    var status = "Lade Collection …"
    var sourceURL: URL?
    private(set) var byKey: [String: Track] = [:]
    /// Roh-Einträge der collection.nml (für NML-Exporte: History, Preparation)
    @ObservationIgnored private(set) var entryIndex = NMLEntryIndex()
    private var smartCache: [UUID: [Track]] = [:]
    @ObservationIgnored private var customCache: [UUID: (query: String, tracks: [Track])] = [:]

    /// Eigene Smartlists (Smartlist-Regel-Syntax), gespeichert in UserDefaults
    var customSmartlists: [CustomSmartlist] = CustomSmartlist.load() {
        didSet { revision += 1; CustomSmartlist.save(customSmartlists) }
    }

    /// Preparation: wird gespeichert, beim nächsten Start archiviert und geleert
    var preparation: [String] = UserDefaults.standard.stringArray(forKey: "prep.current") ?? [] {
        didSet {
            revision += 1
            UserDefaults.standard.set(preparation, forKey: "prep.current")
            UserDefaults.standard.set(Date(), forKey: "prep.date")
        }
    }
    @ObservationIgnored var preparationArchived = false
    var preparationDate: Date { UserDefaults.standard.object(forKey: "prep.date") as? Date ?? Date() }
    /// einmal nach dem ersten Laden der Collection
    @ObservationIgnored var onLoaded: (() -> Void)?
    /// MUSIC FOLDERS (Dateibaum der Musik-Ordner)
    let folders = MusicFolderStore()

    /// Track zu einem Schlüssel: Collection oder schon angezeigte Datei aus MUSIC FOLDERS
    func track(_ key: String) -> Track? { byKey[key] ?? folders.loose[key] }

    /// Änderungszähler einer Quelle zusätzlich zu `revision` (Browser-Zwischenspeicher)
    func sourceRevision(_ s: BrowserSource, subfolders: Bool = false) -> Int {
        switch s {
        case .running: runningRevision
        case let .folder(p): folders.stamp(p, recursive: subfolders)
        default: 0
        }
    }

    /// eigene Metadaten-Änderungen (Browser: Inline, Bearbeiten-Fenster), liegen über der Collection
    @ObservationIgnored let meta = MetadataStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("metadata.json"))
    /// Collection-Stand bearbeiteter Tracks (vor den eigenen Änderungen) – für „Änderungen verwerfen“
    @ObservationIgnored private var collectionBase: [String: Track] = [:]
    @ObservationIgnored private var position: [String: Int] = [:]
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writing = false

    func load(_ url: URL = LibraryStore.defaultNML) {
        status = "Lade \(url.lastPathComponent) …"
        let meta = meta
        Task.detached(priority: .userInitiated) {
            do {
                let start = Date()
                var c = try NMLParser.parse(url: url)
                // Datei-Existenz einmal parallel prüfen (statt pro Tabellenzeile)
                let paths = c.tracks.map(\.path)
                var missing = [Bool](repeating: false, count: paths.count)
                missing.withUnsafeMutableBufferPointer { buf in
                    let b = buf
                    DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                        b[i] = !FileManager.default.fileExists(atPath: paths[i])
                    }
                }
                for i in c.tracks.indices { c.tracks[i].fileMissing = missing[i] }
                // eigene Metadaten-Änderungen über die Collection legen
                var collectionBase: [String: Track] = [:]
                for i in c.tracks.indices {
                    guard let e = meta.edit(for: c.tracks[i].key) else { continue }
                    collectionBase[c.tracks[i].key] = c.tracks[i]
                    c.tracks[i] = e.apply(to: c.tracks[i])
                }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let index = NMLEntryIndex(nmlText: text)
                // MUSIC FOLDERS: Pfad-Index und Standard-Ordner einmal je Collection
                let folderIndex = MusicFolder.pathIndex(c.tracks)
                let folderRoot = MusicFolder.defaultRoot(paths: c.tracks.filter(\.fileExists).map(\.path))
                let base = collectionBase
                let secs = Date().timeIntervalSince(start)
                await MainActor.run {
                    self.tracks = c.tracks
                    self.byKey = Dictionary(c.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                    self.position = Dictionary(c.tracks.indices.map { (c.tracks[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
                    self.collectionBase = base
                    self.entryIndex = index
                    self.folders.collectionLoaded(index: folderIndex, defaultRoot: folderRoot)
                    self.onLoaded?()
                    self.root = c.root
                    self.smartCache = [:]
                    self.customCache = [:]
                    self.sourceURL = url
                    self.status = "\(c.tracks.count) Tracks · \(url.lastPathComponent) · \(String(format: "%.1f", secs)) s"
                }
            } catch {
                await MainActor.run { self.status = "Fehler beim Laden: \(error)" }
            }
        }
    }

    // MARK: - Metadaten bearbeiten

    /// Änderungen übernehmen (Track-Schlüssel -> Feld -> kanonischer Wert): sofort in Liste, Suche, Sortierung;
    /// gespeichert in metadata.json; mit `writeBack` danach (gesammelt, einmal je Stapel) in die Collection-Datei.
    func applyEdits(_ changes: [String: [TrackField: String]], writeBack: Bool) {
        var list = tracks
        var applied: [String: [TrackField: String]] = [:]
        for (key, fields) in changes {
            guard let i = position[key], i < list.count, list[i].key == key else { continue }
            var t = list[i]
            let valid = fields.filter { f, v in f.isEditable(t) && f.normalize(v) == v && f.value(of: t) != v }
            guard !valid.isEmpty else { continue }
            if collectionBase[key] == nil { collectionBase[key] = t }
            for (f, v) in valid { f.set(v, on: &t) }
            t.buildSearchText()
            list[i] = t
            byKey[key] = t
            applied[key] = valid
        }
        guard !applied.isEmpty else { return }
        meta.merge(applied, base: collectionBase)
        replaceRunning(applied.keys)
        smartCache = [:]
        customCache = [:]
        tracks = list
        if writeBack { scheduleWriteBack() }
    }

    /// eigene Änderungen verwerfen -> wieder die Werte der Collection
    func revertEdits(_ keys: [String]) {
        var list = tracks
        var reverted: [String] = []
        for key in keys {
            guard let b = collectionBase[key], let i = position[key], i < list.count, list[i].key == key else { continue }
            var t = b
            t.fileMissing = list[i].fileMissing
            list[i] = t
            byKey[key] = t
            collectionBase[key] = nil
            reverted.append(key)
        }
        meta.remove(keys)
        guard !reverted.isEmpty else { return }
        replaceRunning(reverted)
        smartCache = [:]
        customCache = [:]
        tracks = list
    }

    func hasEdits(_ keys: some Sequence<String>) -> Bool { keys.contains { meta.edit(for: $0) != nil } }

    private func replaceRunning(_ keys: some Sequence<String>) {
        let set = Set(keys)
        if running.contains(where: { set.contains($0.key) }) { running = running.map { byKey[$0.key] ?? $0 } }
    }

    /// Schreiben in die Collection-Datei gesammelt nach kurzer Pause (mehrere Übernahmen = ein Schreibvorgang)
    func scheduleWriteBack() {
        writeTask?.cancel()
        writeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.flushWriteBack()
        }
    }

    /// alle noch nicht geschriebenen Änderungen in die Collection-Datei: Sicherung, textgenaues Ersetzen der
    /// ENTRY-Blöcke, atomar. Geschriebene Felder verlassen danach metadata.json (die Datei hat sie jetzt).
    func flushWriteBack() {
        guard !Session.isSelfTest, let url = sourceURL else { return }
        guard !writing else { scheduleWriteBack(); return }
        let pending = meta.all.mapValues(\.values).filter { position[$0.key] != nil }
        guard !pending.isEmpty else { return }
        if Self.collectionSoftwareRunning() {
            status = String(localized: "Collection-Datei nicht geschrieben: die Collection-Software läuft. Änderungen bleiben in MINOS-741.")
            return
        }
        writing = true
        let index = entryIndex
        let backupDir = url.deletingLastPathComponent().appendingPathComponent("Backup MINOS-741")
        Task.detached(priority: .utility) {
            let result = Result { try CollectionWriter.write(url: url, changes: pending, index: index, backupDir: backupDir) }
            await MainActor.run {
                self.writing = false
                switch result {
                case let .success(r):
                    self.entryIndex.update(r.blocks)
                    self.meta.clear(written: r.written)
                    for k in r.written.keys { self.collectionBase[k] = nil }
                    var msg = String(localized: "Collection-Datei geschrieben: \(r.written.count) Tracks")
                    if let b = r.backup { msg += " · " + String(localized: "Sicherung \(b.lastPathComponent)") }
                    if !r.missing.isEmpty {
                        msg += " · " + String(localized: "\(r.missing.count) nicht gefunden (Datei inzwischen geändert -> ↻ neu laden)")
                    }
                    self.status = msg
                case let .failure(e):
                    self.status = String(localized: "Collection-Datei nicht geschrieben: \(String(describing: e))")
                }
            }
        }
    }

    func tracks(for source: BrowserSource) -> [Track] {
        switch source {
        case .collection: return tracks
        case .preparation: return preparation.compactMap { track($0) }
        case .running: return running
        case .history, .historyLive: return []
        case .prepArchive: return []   // löst BrowserPaneModel über den HistoryStore auf
        case let .custom(sl):
            if let hit = customCache[sl.id], hit.query == sl.query { return hit.tracks }
            let q = (try? SmartQuery.parse(sl.query)) ?? .compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
            let res = tracks.filter { q.matches($0) }
            customCache[sl.id] = (sl.query, res)
            return res
        case let .folder(p): return folders.tracks(in: p, recursive: false, library: self)
        case let .node(n):
            switch n.kind {
            case .folder: return []
            case .playlist: return n.trackKeys.compactMap { byKey[$0] }
            case .smartlist:
                if let hit = smartCache[n.id] { return hit }
                let q = (try? SmartQuery.parse(n.query)) ?? .compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
                let res = tracks.filter { q.matches($0) }
                smartCache[n.id] = res
                return res
            }
        }
    }
}

enum BrowserSource: Hashable {
    case collection
    case preparation
    case running
    case node(PlaylistNode)
    case historyLive
    case history(HistorySession)
    case prepArchive(HistorySession)
    case custom(CustomSmartlist)
    /// Ordner aus MUSIC FOLDERS (absoluter Pfad)
    case folder(String)

    var title: String {
        switch self {
        case .collection: "Track Collection"
        case .preparation: "Preparation"
        case .running: "Running Tracks"
        case let .node(n): n.name
        case .historyLive: "History"
        case let .history(s): "History " + (s.label ?? Theme.dateTimeFormat.string(from: s.date))
        case let .prepArchive(s): "Preparation " + Theme.dateTimeFormat.string(from: s.date)
        case let .custom(c): c.name
        case let .folder(p): (p as NSString).lastPathComponent
        }
    }

    var isHistory: Bool {
        switch self {
        case .historyLive, .history: true
        default: false
        }
    }
}

/// Eigene Smartlist: Name + Regel in Smartlist-Syntax (z. B. `$COMMENT2 % "BASIS" & $BPM >= 128`)
struct CustomSmartlist: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var query: String

    static func load() -> [CustomSmartlist] {
        guard let d = UserDefaults.standard.data(forKey: "smartlists.custom"),
              let l = try? JSONDecoder().decode([CustomSmartlist].self, from: d) else { return [] }
        return l
    }
    static func save(_ l: [CustomSmartlist]) {
        if let d = try? JSONEncoder().encode(l) { UserDefaults.standard.set(d, forKey: "smartlists.custom") }
    }
}

/// Browser-Bereiche und welcher zuletzt benutzt wurde (Ziel für Controller-Browse/Load).
@MainActor @Observable
final class BrowserState {
    let paneA = BrowserPaneModel(name: "Basis")
    let paneB = BrowserPaneModel(name: "Layer")
    var activePaneID: UUID?
    /// Wird von Controllern gesetzt, damit die Liste zur Auswahl scrollt
    var scrollRequest: (pane: UUID, track: Track.ID)?
    @ObservationIgnored weak var store: LibraryStore?
    @ObservationIgnored weak var history: HistoryStore?
    @ObservationIgnored var separators: () -> String = { " " }

    var activePane: BrowserPaneModel { activePaneID == paneB.id ? paneB : paneA }
    /// Browser groß (Decks ausgeblendet) – Leertaste oder Browse-Knopf am Controller
    var maximized = false { didSet { if maximized != oldValue { ToggleProbe.toggled(maximized) } } }

    func pane(_ i: Int) -> BrowserPaneModel { i == 1 ? paneB : paneA }

    func selectedTrack(pane i: Int? = nil) -> Track? {
        let p = i.map(pane) ?? activePane
        guard let store, let id = p.selection.first else { return nil }
        return store.track(id)
    }

    func moveSelection(by delta: Int, pane i: Int? = nil) {
        guard let store else { return }
        let pane = i.map(self.pane) ?? activePane
        activePaneID = pane.id
        let rows = pane.rows(from: store, history: history, separators: separators())
        guard !rows.isEmpty else { return }
        let current = pane.selection.first.flatMap { id in rows.firstIndex { $0.id == id } } ?? -1
        let next = max(0, min(rows.count - 1, current + delta))
        pane.selection = [rows[next].id]
        scrollRequest = (pane.id, rows[next].id)
    }
}
