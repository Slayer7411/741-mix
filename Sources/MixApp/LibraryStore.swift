import AppKit
import SwiftUI
import Observation
import MixCore
import MixEngine

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
    /// zählt jede Änderung der Tracks (für Browser-Zwischenspeicher). Preparation und eigene Smartlists zählen getrennt
    /// (`sourceRevision`): sonst sortierte „An Preparation anhängen“ jeden Bereich neu, auch die Collection
    private(set) var revision = 0
    var root = PlaylistNode(name: "Playlists", kind: .folder)
    /// Tracks, die gerade auf den Decks liegen (A-D) – Quelle RUNNING TRACKS
    var running: [Track] = [] { didSet { runningRevision += 1 } }
    private(set) var runningRevision = 0
    var status = "Lade Collection …"
    var sourceURL: URL?
    /// nicht beobachtet: ändert sich nur zusammen mit `tracks` (Setzen eines beobachteten Wörterbuchs vergleicht alt
    /// mit neu – 14k Einträge, ~30 ms Hauptthread je Laden)
    @ObservationIgnored private(set) var byKey: [String: Track] = [:]
    /// Roh-Einträge der collection.nml (für NML-Exporte: History, Preparation)
    @ObservationIgnored private(set) var entryIndex = NMLEntryIndex()
    private var smartCache: [UUID: [Track]] = [:]
    /// Playlist-Knoten nach ID (aktueller Baum)
    @ObservationIgnored private var nodes: [UUID: PlaylistNode] = [:]
    @ObservationIgnored private var customCache: [UUID: (query: String, tracks: [Track])] = [:]

    /// Eigene Smartlists (Smartlist-Regel-Syntax), gespeichert in UserDefaults
    var customSmartlists: [CustomSmartlist] = CustomSmartlist.load() {
        didSet { smartlistRevision += 1; if !Session.isSelfTest { CustomSmartlist.save(customSmartlists) } }
    }
    private(set) var smartlistRevision = 0

    /// Preparation: wird gespeichert, beim nächsten Start archiviert und geleert (Selbsttest/Messung: nur im Speicher)
    var preparation: [String] = Session.isSelfTest ? [] : UserDefaults.standard.stringArray(forKey: "prep.current") ?? [] {
        didSet {
            preparationRevision += 1
            guard !Session.isSelfTest else { return }
            UserDefaults.standard.set(preparation, forKey: "prep.current")
            UserDefaults.standard.set(Date(), forKey: "prep.date")
        }
    }
    private(set) var preparationRevision = 0
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
        case .preparation: preparationRevision
        case .custom: smartlistRevision
        case let .folder(p): folders.stamp(p, recursive: subfolders)
        default: 0
        }
    }

    /// eigene Metadaten-Änderungen (Browser: Inline, Bearbeiten-Fenster), liegen über der Collection
    @ObservationIgnored let meta = MetadataStore(url: Session.isSelfTest ? nil : HistoryStore.baseDir.appendingPathComponent("metadata.json"))
    /// eigene Analysen (Tempo, Grid, Tonart, Lautheit) – liegen über Collection und Metadaten-Änderungen
    @ObservationIgnored var analysis: AnalysisStore { Analyses.shared.store }
    /// Collection-Stand bearbeiteter / analysierter Tracks (vor den eigenen Werten) – für „verwerfen“
    @ObservationIgnored private var collectionBase: [String: Track] = [:]
    @ObservationIgnored private var position: [String: Int] = [:]
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var writing = false

    /// Laden/Neu-Laden: alles Teure im Hintergrund (Parsen, Datei-Check, eigene Änderungen, Indizes, Sortierung
    /// der sichtbaren Listen), auf dem Hauptthread nur noch eine Übergabe. Vorher hingen ↻ und ⌘O im Set
    /// 1–2 s (zwei Bereiche à ~540 ms lokalisiertes Sortieren von 14k Tracks plus Indizes und Freigabe der alten Liste).
    func load(_ url: URL = LibraryStore.defaultNML) {
        status = "Lade \(url.lastPathComponent) …"
        StatusCenter.post(.info, String(localized: "Collection wird geladen: \(url.lastPathComponent)"), detail: url.path, key: "collection")
        let meta = meta, analysis = analysis
        let first = tracks.isEmpty
        loadGeneration += 1
        let generation = loadGeneration
        // erster Start mit Vorrang, Neu-Laden im Set nachrangig (Decks laden und dekodieren zuerst)
        Task.detached(priority: first ? .userInitiated : .utility) {
            do {
                let start = CACurrentMediaTime()
                var c = try NMLParser.parse(url: url)
                // Datei-Existenz einmal parallel prüfen (statt pro Tabellenzeile). Mit Datei-Dienst im Helfer (hängt der
                // Cloud-Anbieter, wird der Helfer abgeschossen, unbekannte Pfade gelten als vorhanden)
                let paths = c.tracks.map(\.path)
                var missing = [Bool](repeating: false, count: paths.count)
                if let fs = FileServiceSetup.shared, !fs.unavailable {
                    let t0 = CACurrentMediaTime()
                    let states = fs.check(paths: paths)
                    for i in paths.indices { missing[i] = states[i] == .missing || states[i] == .error }   // wie fileExists: Fehler = fehlt
                    let unknown = states.lazy.filter { $0 == nil }.count
                    print(String(format: "[files] %d pfade geprüft (helfer): %.0f ms · fehlen %d · unbekannt %d", paths.count,
                                 (CACurrentMediaTime() - t0) * 1000, missing.lazy.filter { $0 }.count, unknown))
                } else {
                    missing.withUnsafeMutableBufferPointer { buf in
                        let b = buf
                        DispatchQueue.concurrentPerform(iterations: paths.count) { i in
                            b[i] = !FileManager.default.fileExists(atPath: paths[i])
                        }
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
                // eigene Analysen darüber
                if analysis.count > 0 {
                    for i in c.tracks.indices {
                        guard let a = analysis.entry(for: c.tracks[i].key) else { continue }
                        if collectionBase[c.tracks[i].key] == nil { collectionBase[c.tracks[i].key] = c.tracks[i] }
                        c.tracks[i] = a.apply(to: c.tracks[i])
                    }
                }
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let index = NMLEntryIndex(nmlText: text)
                // MUSIC FOLDERS: Pfad-Index und Standard-Ordner einmal je Collection
                let folderIndex = MusicFolder.pathIndex(c.tracks)
                let folderRoot = MusicFolder.defaultRoot(paths: c.tracks.filter(\.fileExists).map(\.path))
                let parsedByKey = Dictionary(c.tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                let base = collectionBase
                let parsedRoot = c.root
                let parsed = CACurrentMediaTime()
                // erster Start: Playlists und Sitzung (Quellen, Sortierung der Bereiche) vorab, damit gleich die
                // richtigen Listen vorsortiert werden; Neu-Laden: nur nachsehen, was die Bereiche gerade zeigen
                let (targets, old, oldByKey, previous, oldRoot): ([PresortKey], [Track], [String: Track], [PresortKey: [Track]], PlaylistNode) = await MainActor.run {
                    if first {
                        self.root = parsedRoot
                        self.byKey = parsedByKey
                        self.entryIndex = index
                        self.onLoaded?()
                        return (self.presortTargets(), [], [:], [:], parsedRoot)
                    }
                    return (self.presortTargets(), self.tracks, self.byKey, self.presorted, self.root)
                }
                var tracks = c.tracks, byKey = parsedByKey, root = parsedRoot
                // Neu-Laden: unveränderte Tracks als dieselben Werte übernehmen (gleicher Speicher). SwiftUI vergleicht
                // die alte mit der neuen Liste – mit geteilten Texten ist das ein Zeigervergleich statt 14k Textvergleichen
                if !oldByKey.isEmpty {
                    var same = 0
                    for i in tracks.indices {
                        if let o = oldByKey[tracks[i].key], o == tracks[i] { tracks[i] = o; same += 1 }
                    }
                    if same == tracks.count, tracks == old { tracks = old }
                    byKey = Dictionary(tracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
                }
                // Playlist-Baum: gleiche Knoten behalten ihre ID, unveränderter Baum bleibt derselbe (Baum-Liste ohne Neuaufbau)
                if !first {
                    root.adoptIDs(from: oldRoot)
                    if root.sameTree(oldRoot) { root = oldRoot }
                }
                var nodes: [UUID: PlaylistNode] = [:]
                root.index(into: &nodes)
                let position = Dictionary(tracks.indices.map { (tracks[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
                let pre = Self.presort(targets, tracks: tracks, byKey: byKey, nodes: nodes, previous: previous)
                let sorted = CACurrentMediaTime()
                let newTracks = tracks, newByKey = byKey, newRoot = root, newNodes = nodes
                await MainActor.run {
                    guard generation == self.loadGeneration else { return }   // inzwischen neuer Ladevorgang
                    let t0 = CACurrentMediaTime()
                    // alte Liste und Indizes nicht hier freigeben (14k Tracks freigeben kostet den Hauptthread ~50 ms)
                    Self.releaseLater((self.tracks, self.byKey, self.position, self.collectionBase, self.entryIndex,
                                       self.smartCache, self.customCache, self.presorted))
                    self.tracks = newTracks
                    self.byKey = newByKey
                    self.position = position
                    self.collectionBase = base
                    self.entryIndex = index
                    self.smartCache = pre.smart
                    self.customCache = pre.custom
                    self.presorted = pre.lists
                    self.presortRevision = self.revision
                    self.folders.collectionLoaded(index: folderIndex, defaultRoot: folderRoot)
                    self.onLoaded?()   // einmal je Start (prüft selbst)
                    if first, !Session.isSelfTest, AppPrefs.load().ui.checkOnStart { ConsistencyWindow.show(store: self) }
                    if self.root !== newRoot { self.root = newRoot }
                    self.nodes = newNodes
                    self.sourceURL = url
                    self.status = "\(newTracks.count) Tracks · \(url.lastPathComponent) · \(String(format: "%.1f", parsed - start)) s"
                    StatusCenter.post(.ok, String(localized: "Collection geladen: \(newTracks.count) Tracks"), detail: url.path, key: "collection")
                    if Self.debug {
                        print(String(format: "[load] %d tracks · parsen+indizes %.0f ms · vorsortieren %d listen %.0f ms (hintergrund) · übergabe %.1f ms (hauptthread)",
                                     newTracks.count, (parsed - start) * 1000, pre.lists.count, (sorted - parsed) * 1000, (CACurrentMediaTime() - t0) * 1000))
                        fflush(stdout)
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = "Fehler beim Laden: \(error)"
                    StatusCenter.post(.error, String(localized: "Collection nicht geladen: \(error.localizedDescription)"), detail: url.path, key: "collection")
                }
            }
        }
    }

    nonisolated static let debug = ProcessInfo.processInfo.environment["MIX741_DEBUG"] == "1" || ProcessInfo.processInfo.environment["MIX741_BENCH"] != nil
    @ObservationIgnored private var loadGeneration = 0

    /// Quelle + Sortierung einer vorsortierten Liste
    struct PresortKey: Hashable, @unchecked Sendable {
        var source: BrowserSource
        var order: [KeyPathComparator<Track>]
    }
    /// Browser-Zustand (für die Ziele des Vorsortierens)
    @ObservationIgnored weak var browser: BrowserState?
    /// im Hintergrund sortierte Listen der Bereiche; gültig nur für `presortRevision`
    @ObservationIgnored private var presorted: [PresortKey: [Track]] = [:]
    @ObservationIgnored private var presortRevision = -1

    /// vorsortierte Liste für einen Bereich (nil = selbst sortieren)
    func presorted(_ source: BrowserSource, order: [KeyPathComparator<Track>]) -> [Track]? {
        guard presortRevision == revision else { return nil }
        return presorted[PresortKey(source: source, order: order)]
    }

    private func presortTargets() -> [PresortKey] {
        guard let b = browser else { return [PresortKey(source: .collection, order: [KeyPathComparator(\Track.artist)])] }
        return Array(Set([b.paneA, b.paneB].map { PresortKey(source: $0.source, order: $0.sortOrder) }))
    }

    /// Basisliste einer Quelle ohne Hauptthread (nur Quellen, die allein aus der Collection kommen)
    nonisolated private static func baseTracks(_ s: BrowserSource, tracks: [Track], byKey: [String: Track],
                                               nodes: [UUID: PlaylistNode]) -> [Track]? {
        let none = SmartQuery.compare(field: "TITLE", op: .eq, value: .text("\u{0}"))
        switch s {
        case .collection: return tracks
        case let .custom(sl):
            let q = (try? SmartQuery.parse(sl.query)) ?? none
            return tracks.filter { q.matches($0) }
        case let .node(old):
            let n = nodes[old.id] ?? old
            switch n.kind {
            case .folder: return nil
            case .playlist: return n.trackKeys.compactMap { byKey[$0] }
            case .smartlist:
                let q = (try? SmartQuery.parse(n.query)) ?? none
                return tracks.filter { q.matches($0) }
            }
        default: return nil
        }
    }

    private struct Presorted: @unchecked Sendable {
        var lists: [PresortKey: [Track]] = [:]
        var smart: [UUID: [Track]] = [:]
        var custom: [UUID: (query: String, tracks: [Track])] = [:]
    }

    /// Listen der Bereiche parallel sortieren (gleiches `TrackSort` wie im Bereich, nur nicht auf dem Hauptthread)
    /// Gleiche Liste wie beim letzten Laden -> derselbe Speicher: die Tabelle sieht keine Änderung und baut nichts neu.
    nonisolated private static func presort(_ targets: [PresortKey], tracks: [Track], byKey: [String: Track],
                                            nodes: [UUID: PlaylistNode], previous: [PresortKey: [Track]]) -> Presorted {
        var out = Presorted()
        var results = [[Track]?](repeating: nil, count: targets.count)
        var bases = [[Track]?](repeating: nil, count: targets.count)
        results.withUnsafeMutableBufferPointer { r in
            bases.withUnsafeMutableBufferPointer { b in
                let r = r, b = b
                DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                    guard let base = baseTracks(targets[i].source, tracks: tracks, byKey: byKey, nodes: nodes) else { return }
                    b[i] = base
                    let list = TrackSort.sorted(base, using: targets[i].order)
                    if let prev = previous[targets[i]], prev == list { r[i] = prev } else { r[i] = list }
                }
            }
        }
        for (i, t) in targets.enumerated() {
            guard let list = results[i], let base = bases[i] else { continue }
            out.lists[t] = list
            switch t.source {
            case let .custom(sl): out.custom[sl.id] = (sl.query, base)
            case let .node(n) where n.kind == .smartlist: out.smart[n.id] = base
            default: break
            }
        }
        return out
    }

    /// letzte Referenz im Hintergrund abgeben: das Freigeben großer Listen kostet sonst den Hauptthread
    nonisolated private static func releaseLater(_ old: Any) {
        let box = OldBox(old)
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 1) { box.drop() }
    }
    private final class OldBox: @unchecked Sendable {
        private var value: Any?
        init(_ v: Any) { value = v }
        func drop() { value = nil }
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
        StatusCenter.post(.ok, String(localized: "Gespeichert: \(applied.count) Tracks (Metadaten)"), key: "edits")
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
            if let a = analysis.entry(for: key) { t = a.apply(to: t) } else { collectionBase[key] = nil }
            list[i] = t
            byKey[key] = t
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
    func hasAnalysis(_ keys: some Sequence<String>) -> Bool { keys.contains { analysis.entry(for: $0) != nil } }

    // MARK: - Eigene Analyse

    /// neue Analysen über die Tracks legen (Collection, lose Dateien aus MUSIC FOLDERS, RUNNING TRACKS)
    func applyAnalyses(_ keys: Set<String>) {
        var list = tracks
        var hit: [String] = []
        for key in keys {
            guard let a = analysis.entry(for: key) else { continue }
            if let i = position[key], i < list.count, list[i].key == key {
                if collectionBase[key] == nil, !list[i].ownAnalysis { collectionBase[key] = list[i] }
                let t = a.apply(to: list[i])
                list[i] = t
                byKey[key] = t
                hit.append(key)
            } else if folders.loose[key] != nil {
                folders.applyAnalysis(a, to: key)
            }
        }
        guard !hit.isEmpty else { return }
        replaceRunning(hit)
        smartCache = [:]
        customCache = [:]
        tracks = list
    }

    /// eigene Analyse verwerfen -> wieder die Werte der Collection (Metadaten-Änderungen bleiben)
    func discardAnalysis(_ keys: [String]) {
        var list = tracks
        var hit: [String] = []
        for key in keys where analysis.entry(for: key) != nil {
            if let b = collectionBase[key], let i = position[key], i < list.count, list[i].key == key {
                var t = b
                t.fileMissing = list[i].fileMissing
                if let e = meta.edit(for: key) { t = e.apply(to: t) } else { collectionBase[key] = nil }
                list[i] = t
                byKey[key] = t
                hit.append(key)
            } else if folders.loose[key] != nil {
                folders.forget(key)
            }
        }
        analysis.remove(keys)
        guard !hit.isEmpty else { return }
        replaceRunning(hit)
        smartCache = [:]
        customCache = [:]
        tracks = list
    }

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
        let analyses = analysis.unwritten.filter { position[$0.key] != nil }
        guard !pending.isEmpty || !analyses.isEmpty else { return }
        if Self.collectionSoftwareRunning() {
            status = String(localized: "Collection-Datei nicht geschrieben: die Collection-Software läuft. Änderungen bleiben in MINOS-741.")
            StatusCenter.post(.warning, status, key: "writeback")
            return
        }
        writing = true
        let index = entryIndex
        let backupDir = url.deletingLastPathComponent().appendingPathComponent("Backup MINOS-741")
        Task.detached(priority: .utility) {
            let result = Result { try CollectionWriter.write(url: url, changes: pending, analyses: analyses, index: index, backupDir: backupDir) }
            await MainActor.run {
                self.writing = false
                switch result {
                case let .success(r):
                    self.entryIndex.update(r.blocks)
                    self.meta.clear(written: r.written)
                    self.analysis.markWritten(r.writtenAnalyses)
                    for k in r.written.keys where self.analysis.entry(for: k) == nil { self.collectionBase[k] = nil }
                    var msg = String(localized: "Collection-Datei geschrieben: \(Set(r.written.keys).union(r.writtenAnalyses).count) Tracks")
                    if let b = r.backup { msg += " · " + String(localized: "Sicherung \(b.lastPathComponent)") }
                    if !r.missing.isEmpty {
                        msg += " · " + String(localized: "\(r.missing.count) nicht gefunden (Datei inzwischen geändert -> ↻ neu laden)")
                    }
                    self.status = msg
                    StatusCenter.post(r.missing.isEmpty ? .ok : .warning, msg, detail: url.path, key: "writeback")
                case let .failure(e):
                    self.status = String(localized: "Collection-Datei nicht geschrieben: \(String(describing: e))")
                    StatusCenter.post(.error, self.status, detail: url.path, key: "writeback")
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
        case let .node(old):
            let n = nodes[old.id] ?? old   // Bereich kann noch den Knoten vor dem Neu-Laden halten (gleiche ID)
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
    @ObservationIgnored weak var store: LibraryStore? { didSet { store?.browser = self } }
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

/// Messung (MIX741_SELFTEST=1 MIX741_BENCH=reload): Collection laden und mehrmals neu laden, beide Browser-Bereiche
/// offscreen in einem nie gezeigten Fenster. Meldet je Ladevorgang die längste Lücke des Hauptthreads (Takt 240 Hz).
@MainActor
enum ReloadBench {
    nonisolated static var requested: Bool { Session.isSelfTest && ProcessInfo.processInfo.environment["MIX741_BENCH"] == "reload" }

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        // Audio nur auf ein eingebautes Gerät (wie SettingsShot), gespeichertes Setup danach unverändert zurück
        let d = UserDefaults.standard
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }
        let store = LibraryStore(), browser = BrowserState(), history = HistoryStore()
        browser.store = store
        browser.history = history
        let root = HSplitView {
            BrowserPane(model: browser.paneA)
            BrowserPane(model: browser.paneB)
        }
        .environment(store).environment(mix).environment(browser)
        .environment(ControllerStatus()).environment(WaveformCache()).environment(history)
        let host = NSHostingView(rootView: root)
        let rect = NSRect(x: 0, y: 0, width: 1600, height: 700)
        let win = NSWindow(contentRect: rect, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        win.contentView = host
        host.frame = rect
        func log(_ s: String) { print("[bench] \(s)"); fflush(stdout) }
        var last = CACurrentMediaTime(), worst = 0.0
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime()
            worst = max(worst, now - last)
            if now - last > 0.03 { print(String(format: "[hitch] %.3f: %.0f ms", now, (now - last) * 1000)) }
            last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        Task { @MainActor in
            let rounds = Int(ProcessInfo.processInfo.environment["MIX741_BENCH_N"] ?? "") ?? 5
            var gaps: [Double] = []
            let probe = AudioProbe(core: mix.core)
            for i in 0...rounds {
                let rev = store.revision
                try? await Task.sleep(for: .milliseconds(300))
                if i == 1, let t = store.tracks.first(where: { $0.bpm > 0 && $0.fileExists && $0.duration > 120 }) {
                    // ab dem ersten Neu-Laden spielt Deck A (stumm): Audio und Steuer-Thread dürfen nicht hängen
                    mix.core.load(t, deck: 0)
                    while mix.core.trackAudio(0) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                    mix.core.togglePlay(0)
                    try? await Task.sleep(for: .milliseconds(300))
                    probe.start()
                }
                probe.reset()
                worst = 0
                let t0 = CACurrentMediaTime()
                // MIX741_BENCH_ALT=<nml>: abwechselnd eine geänderte Kopie laden (Neu-Laden mit echten Änderungen)
                let alt = ProcessInfo.processInfo.environment["MIX741_BENCH_ALT"].map { URL(fileURLWithPath: $0) }
                store.load(i % 2 == 1 ? alt ?? LibraryStore.defaultNML : LibraryStore.defaultNML)
                while store.revision == rev { try? await Task.sleep(for: .milliseconds(5)) }
                try? await Task.sleep(for: .milliseconds(800))
                let gap = worst * 1000
                if i > 0 { gaps.append(gap) }
                log(String(format: "%@ %d: %d tracks, fertig nach %.2f s, längste Lücke Hauptthread %.0f ms%@",
                           i == 0 ? "laden" : "neu laden", i, store.tracks.count, CACurrentMediaTime() - t0 - 0.8, gap,
                           i == 0 ? "" : probe.report()))
            }
            let s = gaps.sorted()
            log(String(format: "→ neu laden: median %.0f ms, max %.0f ms (n=%d)", s[s.count / 2], s.last ?? 0, s.count))
            mix.core.togglePlay(0)
            exit(0)
        }
        app.run()
        exit(0)
    }
}

/// Messung: Steuer-Queue (Rundlauf eines leeren Blocks) und Wiedergabe-Position von Deck A neben der Uhr, alle 5 ms
/// auf einem eigenen Thread – beides darf beim Laden der Collection nicht stehen bleiben.
final class AudioProbe: @unchecked Sendable {
    private let core: MixController
    private let lock = NSLock()
    private var maxControl = 0.0, maxDrift = 0.0, running = false

    init(core: MixController) { self.core = core }

    func start() {
        guard !running else { return }
        running = true
        Thread.detachNewThread { [self] in
            var lastPos = core.position(0), lastT = CACurrentMediaTime()
            while true {
                Thread.sleep(forTimeInterval: 0.005)
                let t0 = CACurrentMediaTime()
                core.controlQueue.sync {}
                let t1 = CACurrentMediaTime()
                let pos = core.position(0)
                // Abweichung der Position von der Uhr (Tempo 0 %: 1 s Audio je Sekunde); Puffergröße als Rauschen
                let drift = abs((pos - lastPos) - (t1 - lastT))
                lastPos = pos; lastT = t1
                lock.lock()
                maxControl = max(maxControl, t1 - t0)
                maxDrift = max(maxDrift, drift)
                lock.unlock()
            }
        }
    }

    func reset() { lock.lock(); maxControl = 0; maxDrift = 0; lock.unlock() }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        guard running else { return "" }
        return String(format: " · steuer-queue max %.1f ms · audio-position max %.1f ms neben der uhr", maxControl * 1000, maxDrift * 1000)
    }
}
