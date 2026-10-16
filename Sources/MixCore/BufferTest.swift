import Foundation

/// Puffer-Test (⌘, -> AUDIO): Messung je Puffergröße -> Empfehlung. Rein, ohne Gerät (Messung: MixApp/BufferTest.swift)
public enum BufferTest {
    /// Stufen, die getestet werden (nur die, die das Gerät annimmt)
    public static let candidates = [64, 128, 256, 512, 1024]
    /// schwerster Block unter diesem Anteil des Budgets (Prozent, strikt)
    public static let worstLimit = 60.0
    /// schwerster Block über diesem Anteil -> eine Stufe mehr als Sicherheitsreserve (strikt)
    public static let marginAbove = 45.0

    /// Messung einer Stufe über den ganzen Lauf
    public struct Probe: Equatable, Sendable {
        public var frames: Int
        /// schwerster Block und Mittel, Prozent der Blockdauer
        public var worstPct: Double
        public var avgPct: Double
        /// Überlasten: Blöcke über dem Budget plus Geräte-Überlastmeldungen (seit Lauf-Beginn)
        public var overruns: Int
        /// Fristabläufe des Watchdogs der parallelen Decks (seit Lauf-Beginn)
        public var watchdogTimeouts: Int
        /// false = Lauf abgebrochen oder Ausgabe weg: nicht gewertet
        public var completed: Bool

        public init(frames: Int, worstPct: Double, avgPct: Double, overruns: Int, watchdogTimeouts: Int, completed: Bool = true) {
            self.frames = frames; self.worstPct = worstPct; self.avgPct = avgPct
            self.overruns = overruns; self.watchdogTimeouts = watchdogTimeouts; self.completed = completed
        }
    }

    public struct Recommendation: Equatable, Sendable {
        public enum Reason: Equatable, Sendable {
            /// keine gewertete Messung
            case none
            /// kleinste Stufe ohne Überlast, schwerster Block unter der Grenze
            case safe
            /// wie `safe`, aber eine Stufe mehr wegen der Reserve
            case margin
            /// alle gewerteten Stufen mit Überlast oder über der Grenze
            case noSafe
        }
        public var frames: Int?
        public var reason: Reason
        public init(frames: Int?, reason: Reason) { self.frames = frames; self.reason = reason }
    }

    /// Stufen, die das Gerät annimmt (Bereich in Frames), aufsteigend
    public static func sizes(candidates: [Int] = candidates, range: ClosedRange<Int>) -> [Int] {
        candidates.filter { range.contains($0) }.sorted()
    }

    /// Puffer in ms bei der Gerätesamplerate (ohne Gerät-, Sicherheits- und Stream-Latenz)
    public static func bufferMs(frames: Int, rate: Double) -> Double {
        rate > 0 ? Double(frames) / rate * 1000 : 0
    }

    /// Empfehlung: kleinste gewertete Stufe ohne Überlast und mit schwerstem Block unter `worstLimit`.
    /// Liegt deren schwerster Block über `marginAbove`, die nächstgrößere gewertete Stufe (Reserve).
    /// Unvollständige Läufe zählen nicht. Mehrfache Stufen: die letzte Messung gewinnt.
    public static func recommend(_ probes: [Probe]) -> Recommendation {
        var byFrames: [Int: Probe] = [:]
        for p in probes where p.completed { byFrames[p.frames] = p }
        let sorted = byFrames.values.sorted { $0.frames < $1.frames }
        guard !sorted.isEmpty else { return Recommendation(frames: nil, reason: .none) }
        guard let i = sorted.firstIndex(where: { $0.overruns == 0 && $0.watchdogTimeouts == 0 && $0.worstPct < worstLimit }) else {
            return Recommendation(frames: nil, reason: .noSafe)
        }
        let safe = sorted[i]
        guard safe.worstPct > marginAbove, i + 1 < sorted.count else {
            return Recommendation(frames: safe.frames, reason: .safe)
        }
        return Recommendation(frames: sorted[i + 1].frames, reason: .margin)
    }
}
