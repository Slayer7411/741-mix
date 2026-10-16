import Foundation

/// Marke „andere Decks“ in der Wellenform: wo ein fremdes Deck gegenüber dem Spielkopf dieses Decks läuft.
/// Gleiche Phasenrechnung wie der Code (PhraseCode), nur gegen ein Deck statt gegen den Zähler.
public enum PeerMark {
    /// Abstand in Beats, + = fremdes Deck voraus. Beat-Differenz im Phrasen-Raster, umgebrochen auf −P/2 < x ≤ P/2
    public static func offsetBeats(own: Double, other: Double, phraseBeats: Double) -> Double {
        let p = max(1, phraseBeats)
        let d = other - own
        return d - ((d / p) - 0.5).rounded(.up) * p
    }

    /// Im Takt: höchstens ±1/16 Beat vom Spielkopf (gleiche Stelle in der Phrase, Marke liegt auf dem roten Strich)
    public static func inPhase(_ offset: Double) -> Bool { abs(offset) <= 1.0 / 16 }

    /// Verschiebung der Marke gegen die Mitte in Punkten (Beat-Länge in s × Punkte je s). `limit` = Abstand zur Mitte,
    /// über den hinaus die Marke am Rand klebt (`clamped`)
    public static func place(offsetBeats: Double, beatSeconds: Double, pointsPerSecond: Double, limit: Double)
        -> (dx: Double, clamped: Bool) {
        let raw = offsetBeats * beatSeconds * pointsPerSecond
        let lim = max(0, limit)
        return (min(max(raw, -lim), lim), abs(raw) > lim)
    }

    /// Text am Rand: Abstand in ganzen Beats wie im Code (`+2 BARS`); nil bei 0
    public static func label(_ offset: Double) -> String? { PhraseCode.label(beats: Int(offset.rounded())) }
}
