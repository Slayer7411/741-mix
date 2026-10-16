import Foundation

/// „Code“: Lage eines Decks in seiner Phrase gegenüber dem Bar-Zähler.
/// Phrasenstart = Grid-Anker (Beat 0, wie die Phrasenbänder der Wellenform), Takt 1 des Zählers = Sitzungs-Beat 0.
public struct PhraseCode: Equatable, Sendable {
    /// Phrasenlänge in Takten (4 / 8 / 16 / 32)
    public var phraseBars: Int
    /// Takt des Decks in seiner Phrase, 1-basiert
    public var bar: Int
    /// Abstand zum Zähler in ganzen Beats, + = Deck voraus, umgebrochen auf −P/2 < x ≤ P/2 (nil = Zähler steht)
    public var offsetBeats: Int?

    public init(deckBeat: Double, sessionBeat: Double?, phraseBars: Int) {
        let bars = max(1, phraseBars)
        let perBar = Int(BeatGrid.beatsPerBar)
        self.phraseBars = bars
        let b = Int((deckBeat / BeatGrid.beatsPerBar).rounded(.down))
        bar = ((b % bars) + bars) % bars + 1
        offsetBeats = sessionBeat.map { Self.wrap(Int((deckBeat - $0).rounded()), beats: bars * perBar) }
    }

    /// Beats auf eine Phrase umbrechen: −P/2 < x ≤ P/2
    public static func wrap(_ beats: Int, beats p: Int) -> Int {
        var m = ((beats % p) + p) % p
        if m > p / 2 { m -= p }
        return m
    }

    /// Deck liegt im Code (gleicher Takt in der Phrase, gleicher Beat)
    public var aligned: Bool { offsetBeats == 0 }

    /// Abweichung als Text: ganze Takte (`+2 BARS`, `−1 BAR`), sonst Beats (`+3 BEATS`); nil = im Code / kein Zähler
    public var offsetLabel: String? { offsetBeats.flatMap(Self.label) }

    /// Abstand in ganzen Beats als Text (siehe `offsetLabel`); nil bei 0
    public static func label(beats o: Int) -> String? {
        guard o != 0 else { return nil }
        let perBar = Int(BeatGrid.beatsPerBar)
        let sign = o > 0 ? "+" : "\u{2212}"
        let (n, unit) = o % perBar == 0 ? (abs(o) / perBar, "BAR") : (abs(o), "BEAT")
        return "\(sign)\(n) \(unit)\(n == 1 ? "" : "S")"
    }
}
