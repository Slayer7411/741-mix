import Foundation
import MixCore

/// Bearbeitungsstand eines Decks für Rückgängig: kleine Kopie (kein Audio). `Parts` wählt, was verglichen und
/// wiederhergestellt wird; alles andere bleibt, wie es gerade ist
public struct DeckEdit: Equatable, Sendable {
    public struct Parts: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// Hotcues und Active Loops
        public static let cues = Parts(rawValue: 1 << 0)
        /// Loop (an/aus, Bereich, IN, Größe)
        public static let loop = Parts(rawValue: 1 << 1)
        /// Position (Beatjump, Sprung); wiederhergestellt als Versatz, ein spielendes Deck läuft weiter
        public static let position = Parts(rawValue: 1 << 2)
        public static let grid = Parts(rawValue: 1 << 3)
        /// Schnitt und Cue-Punkt
        public static let trim = Parts(rawValue: 1 << 4)
        /// Key-Shift und Keylock
        public static let key = Parts(rawValue: 1 << 5)
        public static let tempo = Parts(rawValue: 1 << 6)
        public static let sync = Parts(rawValue: 1 << 7)
        public static let master = Parts(rawValue: 1 << 8)
        public static let flux = Parts(rawValue: 1 << 9)
    }

    public var trackKey: String?
    public var hotcues: [Int: Cue] = [:]
    public var activeLoops: Set<Int> = []
    public var grid: BeatGrid?
    public var gridEdited = false
    public var trim = TrackTrim()
    public var cuePoint = 0.0
    public var loopActive = false
    public var loopStart = 0.0, loopEnd = 0.0
    public var loopIn: Double?
    public var loopSize = 4.0
    public var keyShift = 0
    public var keylock = true
    public var tempoPct = 0.0
    public var sync = false
    public var masterDeck: Int?
    public var flux = false
    public var position = 0.0

    public init() {}

    /// kleinste Positionsänderung, die als Sprung zählt (s)
    public static let positionTolerance = 0.005

    /// gleich in den gewählten Teilen
    public func same(as o: DeckEdit, in p: Parts) -> Bool {
        if trackKey != o.trackKey { return false }
        if p.contains(.cues), hotcues != o.hotcues || activeLoops != o.activeLoops { return false }
        if p.contains(.loop), loopActive != o.loopActive || loopIn != o.loopIn || loopSize != o.loopSize
            || (loopActive || o.loopActive) && (abs(loopStart - o.loopStart) > 1e-6 || abs(loopEnd - o.loopEnd) > 1e-6) { return false }
        if p.contains(.position), abs(position - o.position) >= Self.positionTolerance { return false }
        if p.contains(.grid), grid != o.grid || gridEdited != o.gridEdited { return false }
        if p.contains(.trim), trim != o.trim || cuePoint != o.cuePoint { return false }
        if p.contains(.key), keyShift != o.keyShift || keylock != o.keylock { return false }
        if p.contains(.tempo), tempoPct != o.tempoPct { return false }
        if p.contains(.sync), sync != o.sync { return false }
        if p.contains(.master), masterDeck != o.masterDeck { return false }
        if p.contains(.flux), flux != o.flux { return false }
        return true
    }
}
