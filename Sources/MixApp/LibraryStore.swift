import Foundation
import Observation
import MixCore

/// Hält die geladene Collection; alle Browser-Bereiche lesen daraus.
@MainActor @Observable
final class LibraryStore {
    nonisolated static let defaultNML = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Native Instruments/Traktor 3.11.2/collection.nml")

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

    /// Eigene Smartlists (Traktor-Regel-Syntax), gespeichert in UserDefaults
    var customSmartlists: [CustomSmartlist] = CustomSmartlist.load() {
        didSet { revision += 1; CustomSmartlist.save(customSmartlists) }
    }

    /// Preparation (wie Traktor): wird gespeichert, beim nächsten Start archiviert und geleert
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

    func load(_ url: URL = LibraryStore.defaultNML) {
        status = "Lade \(url.lastPathComponent) …"
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
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let index = NMLEntryIndex(nmlText: text)
                let secs = Date().timeIntervalSince(start)
                await MainActor.run {
                    self.tracks = c.tracks
                    self.byKey = Dictionary(c.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                    self.entryIndex = index
                    self.onLoaded?()
                    self.root = c.root
                    self.smartCache = [:]
                    self.sourceURL = url
                    self.status = "\(c.tracks.count) Tracks · \(url.path) · \(String(format: "%.1f", secs)) s"
                }
            } catch {
                await MainActor.run { self.status = "Fehler beim Laden: \(error)" }
            }
        }
    }

    func tracks(for source: BrowserSource) -> [Track] {
        switch source {
        case .collection: return tracks
        case .preparation: return preparation.compactMap { byKey[$0] }
        case .running: return running
        case .history, .historyLive: return []
        case .prepArchive: return []   // löst BrowserPaneModel über den HistoryStore auf
        case let .custom(sl):
            if let hit = customCache[sl.id], hit.query == sl.query { return hit.tracks }
            let q = (try? SmartQuery.parse(sl.query)) ?? .compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
            let res = tracks.filter { q.matches($0) }
            customCache[sl.id] = (sl.query, res)
            return res
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

    var title: String {
        switch self {
        case .collection: "Track Collection"
        case .preparation: "Preparation"
        case .running: "Running Tracks"
        case let .node(n): n.name
        case .historyLive: "History"
        case let .history(s): "History " + Theme.dateTimeFormat.string(from: s.date)
        case let .prepArchive(s): "Preparation " + Theme.dateTimeFormat.string(from: s.date)
        case let .custom(c): c.name
        }
    }

    var isHistory: Bool {
        switch self {
        case .historyLive, .history: true
        default: false
        }
    }
}

/// Eigene Smartlist: Name + Regel im Traktor-Syntax (z. B. `$COMMENT2 % "BASIS" & $BPM >= 128`)
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

/// Browser-Bereiche und welcher zuletzt benutzt wurde (Ziel für X1-Browse/Load).
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
    /// Browser groß (Decks ausgeblendet) – Leertaste oder Browse-Knopf am X1
    var maximized = false

    func pane(_ i: Int) -> BrowserPaneModel { i == 1 ? paneB : paneA }

    func selectedTrack(pane i: Int? = nil) -> Track? {
        let p = i.map(pane) ?? activePane
        guard let store, let id = p.selection.first else { return nil }
        return store.byKey[id]
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
