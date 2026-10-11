import MixCore

/// Vorhören mit Schnitt: gespielter Bereich einer Datei (Sekunden), Startpunkt, Sprungziel, Ende.
/// Ohne Schnitt oder bei ungültigem Schnitt (kürzer als `TrackTrim.minLength`) die ganze Datei – wie das Deck.
struct PreviewCut: Equatable, Sendable {
    let lo: Double, hi: Double
    /// Rand gesetzt (gedimmt / markiert)
    let cutStart: Bool, cutEnd: Bool
    /// Klick hinter dem Ende: so weit vor dem Schnitt-Ende landen (s)
    static let tail = 1.0

    init(trim: TrackTrim?, duration: Double) {
        let d = max(0, duration.isFinite ? duration : 0)
        let t = trim?.normalized(duration: d) ?? TrackTrim()
        let r = t.range(duration: d)
        lo = r.lowerBound; hi = r.upperBound
        cutStart = t.start != nil; cutEnd = t.end != nil
    }

    var length: Double { hi - lo }
    var isCut: Bool { cutStart || cutEnd }

    /// Startpunkt: Anteil `fraction` (Einstellung „Vorhören ab“) des Schnitts, nicht der Datei
    func start(fraction: Double) -> Double { lo + length * min(max(fraction.isFinite ? fraction : 0, 0), 1) }

    /// Sprungziel: vor dem Anfang -> Anfang, hinter dem Ende -> `tail` vor dem Ende, innen unverändert
    func clamp(_ t: Double) -> Double {
        guard t.isFinite else { return lo }
        if t < lo { return lo }
        if t > hi { return max(lo, hi - Self.tail) }
        return t
    }

    /// Restzeit bis zum Schnitt-Ende
    func remaining(at t: Double) -> Double { max(0, hi - min(max(t, lo), hi)) }

    /// am Schnitt-Ende angekommen (20 ms Toleranz: der Player meldet die Position in Blöcken)
    func isOver(_ t: Double) -> Bool { t >= hi - 0.02 }
}
