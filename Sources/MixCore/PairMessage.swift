import Foundation

/// Zwei-Mac-Modus: Nachrichten zwischen Mac 1 (schreibt, Decks A/C) und Mac 2 (Decks B/D), eine JSON-Zeile je Nachricht
public enum PairMessage: Codable, Equatable, Sendable {
    /// nach dem Verbinden: Rolle, Protokoll, eigene Gespielt-Markierungen
    case hello(leader: Bool, version: Int, name: String, played: [String])
    /// Mac 1 -> Mac 2: gemeinsamer Stand nach dem Verbinden
    case playedSet([String])
    /// Änderung der Gespielt-Markierungen (beide Richtungen)
    case played(add: [String], remove: [String])

    public static let version = 1

    public func line() -> Data {
        var d = (try? JSONEncoder().encode(self)) ?? Data()
        d.append(0x0A)
        return d
    }
}

/// zerlegt den TCP-Strom in Zeilen; unlesbare Zeilen fallen weg
public struct PairLineReader: Sendable {
    private var buffer = Data()
    /// Schutz gegen einen Strom ohne Zeilenende
    public static let maxLine = 16 << 20

    public init() {}

    public mutating func feed(_ data: Data) -> [PairMessage] {
        buffer.append(data)
        var out: [PairMessage] = []
        while let i = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<i]
            buffer.removeSubrange(buffer.startIndex...i)
            if let m = try? JSONDecoder().decode(PairMessage.self, from: line) { out.append(m) }
        }
        if buffer.count > Self.maxLine { buffer.removeAll() }
        return out
    }
}

/// gemeinsamer Stand beim Verbinden: nichts geht verloren (Vereinigung)
public enum PairPlayed {
    public static func merged(leader: Set<String>, follower: Set<String>) -> Set<String> { leader.union(follower) }
}
