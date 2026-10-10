import Foundation
import Observation
import MixCore
import MixEngine

/// History und Preparation-Archiv – gespeichert im Traktor-NML-Format, direkt in Traktor importierbar.
@MainActor @Observable
final class HistoryStore {
    static let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MINOS-741")
    static let historyDir = baseDir.appendingPathComponent("History")
    static let prepDir = baseDir.appendingPathComponent("Preparation")
    static let traktorHistoryDir = LibraryStore.defaultNML.deletingLastPathComponent().appendingPathComponent("History")

    /// laufende Session (beginnt mit dem App-Start)
    private(set) var live: [HistoryEntry] = []
    /// schon gespielte Tracks (Haken im Browser), bis „Reset Played State“
    private(set) var played: Set<String> = []
    static let playedURL = baseDir.appendingPathComponent("played.json")
    let sessionStart = Date()
    private(set) var archive: [HistorySession] = []
    private(set) var prepArchive: [HistorySession] = []
    @ObservationIgnored private var cache: [String: [HistoryEntry]] = [:]
    @ObservationIgnored private let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    @ObservationIgnored weak var store: LibraryStore?
    @ObservationIgnored weak var mix: MixModel?
    @ObservationIgnored private var timer: Timer?

    var liveURL: URL { Self.historyDir.appendingPathComponent(TraktorHistoryWriter.fileName(for: sessionStart)) }

    init() {
        try? FileManager.default.createDirectory(at: Self.historyDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.prepDir, withIntermediateDirectories: true)
        if !Session.isSelfTest, let d = try? Data(contentsOf: Self.playedURL), let k = try? JSONDecoder().decode([String].self, from: d) {
            played = Set(k)
        }
        refreshArchive()
    }

    func start(store: LibraryStore, mix: MixModel) {
        self.store = store
        self.mix = mix
        mix.core.onPlayed = { [weak self] d, t, start in
            DispatchQueue.main.async { self?.record(deck: d, track: t, start: start) }
        }
        // Spieldauer der laufenden Einträge alle 5 s nachführen
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDurations() }
        }
    }

    // MARK: History

    func resetPlayed() {
        played = []
        savePlayed()
    }

    private func savePlayed() {
        guard !Session.isSelfTest else { return }
        if let d = try? JSONEncoder().encode(played.sorted()) { try? d.write(to: Self.playedURL, options: .atomic) }
    }

    func record(deck: Int, track t: Track, start: Date) {
        if played.insert(t.key).inserted { savePlayed() }
        live.append(HistoryEntry(key: t.key, title: t.title, artist: t.artist, bpm: t.bpm, keyText: t.openKey,
                                 deck: deck, start: start, duration: mix?.core.playedSeconds(deck) ?? 0))
        save()
    }

    private func updateDurations() {
        guard let mix else { return }
        var changed = false
        for d in 0..<MixEngine.deckCount {
            guard let key = mix.deck(d).track?.key,
                  let i = live.lastIndex(where: { $0.deck == d && $0.key == key }) else { continue }
            let secs = mix.core.playedSeconds(d)
            if secs > live[i].duration + 0.5 { live[i].duration = secs; changed = true }
        }
        if changed { save() }
    }

    private func save() {
        guard !live.isEmpty else { return }
        let text = TraktorHistoryWriter.nml(entries: live, index: store?.entryIndex ?? NMLEntryIndex(), uuid: uuid)
        if ProcessInfo.processInfo.environment["MIX741_SELFTEST"] == "1" { SelfTest.historyURL = liveURL }
        try? text.write(to: liveURL, atomically: true, encoding: .utf8)
        if mix?.prefs.ui.historyToTraktor == true {
            try? text.write(to: Self.traktorHistoryDir.appendingPathComponent(liveURL.lastPathComponent),
                            atomically: true, encoding: .utf8)
        }
        refreshArchive()
    }

    func refreshArchive() {
        func list(_ dir: URL, _ src: HistorySession.Source) -> [HistorySession] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "nml" }
                .compactMap { u in HistorySession.date(fromFileName: u.lastPathComponent).map { HistorySession(url: u, date: $0, source: src) } }
        }
        let own = list(Self.historyDir, .live).filter { $0.url != liveURL }
        let ownNames = Set(own.map(\.url.lastPathComponent))
        let traktor = list(Self.traktorHistoryDir, .traktor).filter { !ownNames.contains($0.url.lastPathComponent) }
        archive = (own + traktor).sorted { $0.date > $1.date }
        prepArchive = list(Self.prepDir, .live).sorted { $0.date > $1.date }
    }

    func entries(_ s: HistorySession) -> [HistoryEntry] {
        if let c = cache[s.id] { return c }
        let e = TraktorHistoryParser.parse(url: s.url)
        cache[s.id] = e
        return e
    }

    // MARK: Preparation-Archiv

    /// Beim Start: Preparation der letzten Session als NML archivieren und leeren (wie Traktor-Workflow, mit Verlauf).
    func archivePreparation(keys: [String], date: Date) {
        guard !keys.isEmpty, let store else { return }
        let name = "Preparation " + Theme.dateFormat.string(from: date)
        let entries = keys.map { k -> HistoryEntry in
            let t = store.byKey[k]
            return HistoryEntry(key: k, title: t?.title ?? "", artist: t?.artist ?? "", bpm: t?.bpm ?? 0,
                                keyText: t?.openKey ?? "", deck: 0, start: date, duration: 0)
        }
        let text = TraktorPlaylistWriter.nml(name: name, entries: entries, index: store.entryIndex)
        let file = TraktorHistoryWriter.fileName(for: date).replacingOccurrences(of: "history_", with: "preparation_")
        try? text.write(to: Self.prepDir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        refreshArchive()
    }

    func prepKeys(_ s: HistorySession) -> [String] {
        (try? NMLParser.parse(url: s.url))?.root.children.first?.trackKeys ?? []
    }
}
