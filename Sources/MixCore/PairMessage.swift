import Foundation

/// Zwei-Mac-Modus: Nachrichten zwischen dem schreibenden Mac und dem anderen, eine JSON-Zeile je Nachricht
public enum PairMessage: Codable, Equatable, Sendable {
    /// nach dem Verbinden: schreibt dieser Mac, seine Decks (0 = A … 3 = D), Protokoll, Gespielt-Markierungen
    case hello(writes: Bool, decks: [Int], version: Int, name: String, played: [String])
    /// schreibender Mac -> anderer: gemeinsamer Stand nach dem Verbinden
    case playedSet([String])
    /// Einstellung geändert (Schalter oben, ⌘,): wer schreibt, welche Decks – übernimmt ein Mac das Schreiben, gibt der andere ab
    case state(writes: Bool, decks: [Int])
    /// LIVE an/aus (kein Ruhezustand), der andere Mac folgt
    case live(Bool)
    /// Änderung der Gespielt-Markierungen (beide Richtungen)
    case played(add: [String], remove: [String])
    /// Fernzugriff: Befehl an den anderen Mac (`command`: ping, snapshot, status, prefs-get, prefs-set, defaults-get, defaults-set)
    case debugRequest(id: Int, command: String, args: String)
    /// Antwort auf `debugRequest`: `body` ist JSON-Text
    case debugReply(id: Int, ok: Bool, body: String)
    /// Takt: Master-Deck spielt dort, und wer führt Link (nach dem Verbinden und bei jeder Änderung; `leader` = Anspruch)
    case clock(playingMaster: Bool, leader: Bool)

    public static let version = 5

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
    public static func merged(_ a: Set<String>, _ b: Set<String>) -> Set<String> { a.union(b) }
}

/// Prüfung beim Verbinden: genau ein Mac schreibt, kein Deck auf beiden
public enum PairCheck {
    public enum Problem: Equatable, Sendable { case bothWrite, noneWrites, sharedDecks([Int]) }

    public static func problems(ownWrites: Bool, ownDecks: [Int], peerWrites: Bool, peerDecks: [Int]) -> [Problem] {
        var p: [Problem] = []
        if ownWrites && peerWrites { p.append(.bothWrite) }
        if !ownWrites && !peerWrites { p.append(.noneWrites) }
        let shared = Set(ownDecks).intersection(peerDecks).sorted()
        if !shared.isEmpty { p.append(.sharedDecks(shared)) }
        return p
    }
}
