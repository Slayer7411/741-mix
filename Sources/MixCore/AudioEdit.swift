import Foundation

/// Audio-Edit-Modus: Arbeitsliste der Import-Analyse. Auswahl (neu importiert oder noch nicht analysiert), Stand je
/// Track und der Stand „erledigt“ / letzter Lauf in `audioedit.json` – nie in der Collection.
public enum AudioEdit {
    /// Stand eines Tracks in der Liste
    public enum Status: Equatable, Sendable {
        /// in der Warteschlange
        case waiting
        /// wird gerade analysiert
        case analysing
        /// offene Befunde der Rip-Prüfung
        case suggestions(Int)
        /// geprüft, nichts vorzuschlagen
        case ok
        /// von Hand als erledigt markiert
        case reviewed
        /// nicht geprüft und nicht in der Warteschlange (z. B. Liste ohne Import-Lauf)
        case unchecked
    }

    /// Stand aus den Teilen. Erledigt schlägt alles, dann laufende Analyse, Warteschlange, ungeprüft, Vorschläge, ok
    public static func status(reviewed: Bool, analysing: Bool, queued: Bool, ripChecked: Bool, open: Int) -> Status {
        if reviewed { return .reviewed }
        if analysing { return .analysing }
        if queued { return .waiting }
        if !ripChecked { return .unchecked }
        return open > 0 ? .suggestions(open) : .ok
    }

    /// noch nicht analysiert: ohne Rip-Prüfung in der aktuellen Fassung, oder ohne eigene Analyse mit fehlenden Werten
    public static func notAnalysed(_ t: Track, ownAnalysis: Bool, ripChecked: Bool) -> Bool {
        !ripChecked || !(ownAnalysis || TrackAnalysis.missing(in: t).isEmpty)
    }

    /// Import-Lauf: Tracks, die seit dem letzten Lauf importiert wurden (`importDate` neuer als `lastRun`; ohne Lauf
    /// zählt keiner so), und alle, die noch nicht analysiert sind. Reihenfolge der Quelle bleibt
    public static func pick(_ tracks: [Track], lastRun: Date?, ownAnalysis: (String) -> Bool, ripChecked: (String) -> Bool) -> [Track] {
        tracks.filter { t in
            let imported = lastRun.flatMap { r in t.importDate.map { $0 > r } } ?? false
            return imported || notAnalysed(t, ownAnalysis: ownAnalysis(t.key), ripChecked: ripChecked(t.key))
        }
    }
}

/// Letzter Import-Lauf und erledigte Tracks (`audioedit.json`); `url` nil = nur im Speicher (Selbsttest)
public final class AudioEditStore: @unchecked Sendable {
    public struct State: Codable, Equatable, Sendable {
        public var lastImport: Date?
        /// Track-Schlüssel -> Zeitpunkt des Erledigt-Markierens
        public var reviewed: [String: Date] = [:]
        public init(lastImport: Date? = nil, reviewed: [String: Date] = [:]) { self.lastImport = lastImport; self.reviewed = reviewed }
    }

    private var state: State
    let url: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.audioedit", qos: .utility)

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: d) { state = s } else { state = State() }
    }

    public var lastImport: Date? { lock.lock(); defer { lock.unlock() }; return state.lastImport }
    public var reviewed: [String: Date] { lock.lock(); defer { lock.unlock() }; return state.reviewed }

    public func isReviewed(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return state.reviewed[key] != nil }

    public func setLastImport(_ d: Date?) {
        lock.lock(); state.lastImport = d; lock.unlock()
        save()
    }

    public func markReviewed(_ key: String, at d: Date = Date()) {
        lock.lock(); state.reviewed[key] = d; lock.unlock()
        save()
    }

    public func unmarkReviewed(_ key: String) {
        lock.lock(); state.reviewed[key] = nil; lock.unlock()
        save()
    }

    /// Import-Lauf und alle erledigt-Markierungen zurücksetzen
    public func reset() {
        lock.lock(); state = State(); lock.unlock()
        save()
    }

    private func save() {
        guard let url else { return }
        lock.lock(); let snapshot = state; lock.unlock()
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? JSONEncoder().encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// wartet, bis alle Schreibvorgänge durch sind (Tests, Beenden)
    public func flush() { queue.sync {} }
}
