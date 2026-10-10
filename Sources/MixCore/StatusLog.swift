import Foundation

/// Eine Meldung der Statusleiste
public struct StatusMessage: Identifiable, Equatable, Sendable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case info, ok, warning, error
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
        /// Anzeigedauer nach der letzten Aktualisierung; nil = bleibt bis Klick oder Ersatz
        public var lifetime: TimeInterval? {
            switch self {
            case .info: 4
            case .ok: 3
            case .warning: 8
            case .error: nil
            }
        }
    }

    public let id: Int
    /// gleicher Schlüssel ersetzt die Meldung an ihrer Stelle (Fortschritt, „Deck A lädt“ …)
    public var key: String?
    public var level: Level
    public var text: String
    /// zweite Zeile (Pfad, Grund)
    public var detail: String?
    /// 0…1 und Text dazu („12/240“)
    public var progress: Double?
    public var progressText: String?
    public var cancellable = false
    public var posted: Date
    public var updated: Date
    public var expires: Date?

    public init(id: Int, key: String? = nil, level: Level, text: String, detail: String? = nil,
                progress: Double? = nil, progressText: String? = nil, cancellable: Bool = false, now: Date = Date()) {
        self.id = id; self.key = key; self.level = level; self.text = text; self.detail = detail
        self.progress = progress; self.progressText = progressText; self.cancellable = cancellable
        posted = now; updated = now
        expires = level.lifetime.map { now.addingTimeInterval($0) }
    }
}

/// Meldungen der Statusleiste: aktive (laufen ab) und Verlauf (die letzten `historyLimit`).
/// Reiner Zustand ohne Uhr – die Zeit kommt von außen (testbar).
public struct StatusLog: Equatable, Sendable {
    /// aktive Meldungen in Reihenfolge des ersten Erscheinens
    public private(set) var active: [StatusMessage] = []
    /// Verlauf, neueste zuerst
    public private(set) var history: [StatusMessage] = []
    public var historyLimit = 50
    private var nextID = 1

    public init() {}

    /// Meldung eintragen; mit Schlüssel ersetzt sie eine aktive gleichen Schlüssels an deren Stelle. Liefert die ID
    @discardableResult
    public mutating func post(_ level: StatusMessage.Level, _ text: String, detail: String? = nil, key: String? = nil,
                              progress: Double? = nil, progressText: String? = nil, cancellable: Bool = false,
                              now: Date = Date()) -> Int {
        if let key, let i = active.firstIndex(where: { $0.key == key }) {
            var m = active[i]
            m.level = level; m.text = text; m.detail = detail
            m.progress = progress.map { min(1, max(0, $0)) }; m.progressText = progressText; m.cancellable = cancellable
            m.updated = now
            m.expires = level.lifetime.map { now.addingTimeInterval($0) }
            active[i] = m
            if let h = history.firstIndex(where: { $0.id == m.id }) { history[h] = m } else { remember(m) }
            return m.id
        }
        let m = StatusMessage(id: nextID, key: key, level: level, text: text, detail: detail,
                              progress: progress.map { min(1, max(0, $0)) }, progressText: progressText,
                              cancellable: cancellable, now: now)
        nextID += 1
        active.append(m)
        remember(m)
        return m.id
    }

    private mutating func remember(_ m: StatusMessage) {
        history.insert(m, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
    }

    /// abgelaufene entfernen; true = etwas hat sich geändert
    @discardableResult
    public mutating func expire(now: Date = Date()) -> Bool {
        let n = active.count
        active.removeAll { $0.expires.map { $0 <= now } ?? false }
        return active.count != n
    }

    public mutating func dismiss(id: Int) { active.removeAll { $0.id == id } }
    public mutating func dismiss(key: String) { active.removeAll { $0.key == key } }
    public mutating func dismissAll() { active.removeAll() }
    public mutating func clearHistory() { history.removeAll() }

    /// angezeigte Meldung: höchste Stufe zuerst (ok zählt wie info), bei gleicher Stufe die zuletzt aktualisierte
    public var current: StatusMessage? {
        func rank(_ l: StatusMessage.Level) -> Int { l == .ok ? StatusMessage.Level.info.rawValue : l.rawValue }
        return active.max { a, b in
            rank(a.level) != rank(b.level) ? rank(a.level) < rank(b.level) : (a.updated, a.id) < (b.updated, b.id)
        }
    }

    /// nächster Ablaufzeitpunkt (für den Takt der Anzeige)
    public var nextExpiry: Date? { active.compactMap(\.expires).min() }
}
