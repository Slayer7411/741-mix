import Foundation

/// Auto-Mix (interner Mixer): Einstellungen (⌘, → MIXER & FX → Auto-Mix)
public struct AutoMixPrefs: Codable, Equatable, Sendable {
    /// Länge des Übergangs in Takten (8 / 16 / 32)
    public var transitionBars = 16
    /// Bass-Tausch in der Mitte des Übergangs (aus: Bass bleibt bis zum Ende beim alten Track)
    public var bassSwap = true
    /// Filter-Sweep: eingehend Hochpass, ausgehend Tiefpass
    public var filterSweep = true
    /// Tonart-Konflikt (Stufe „clash“) als Auswahl erlauben
    public var allowKeyClash = false
    /// Key Sync beim Laden des eingehenden Tracks (Key-Shift zum Master, wie die Taste am Deck)
    public var keySync = true
    public init() {}
}

/// Kandidat im Pool: alles, was die Auswahl braucht (vorab aus dem Track gelesen)
public struct AutoMixCandidate: Hashable, Sendable {
    public var key: String
    public var artist: String
    public var bpm: Double
    /// Key-Code (Harmony), nil = unbekannt
    public var harmony: Int?
    public var tags: TagProfile
    /// Quelle: 0 = Seite A, 1 = Seite B
    public var side: Int
    /// Grid vorhanden (BPM und Anker); ohne Grid kommt der Track nicht in Frage
    public var hasGrid: Bool
    /// Analyse vorhanden (bevorzugt)
    public var analyzed: Bool

    public init(key: String, artist: String, bpm: Double, harmony: Int?, tags: TagProfile, side: Int, hasGrid: Bool, analyzed: Bool) {
        self.key = key; self.artist = artist; self.bpm = bpm; self.harmony = harmony
        self.tags = tags; self.side = side; self.hasGrid = hasGrid; self.analyzed = analyzed
    }
}

/// Bezug: der laufende Track (hörbarer Key, Tempo, Gruppen, Künstler, Seite)
public struct AutoMixRef: Equatable, Sendable {
    public var key: Int?
    public var bpm: Double
    public var tags: TagProfile
    public var artist: String
    public var side: Int?

    public init(key: Int?, bpm: Double, tags: TagProfile, artist: String, side: Int?) {
        self.key = key; self.bpm = bpm; self.tags = tags; self.artist = artist; self.side = side
    }
}

/// Ein Eintrag der Rangliste (kleiner Wert = passender)
public struct AutoMixPick: Equatable, Sendable {
    public var key: String
    public var score: Double
}

/// Auswahl des nächsten Tracks („bester Match“): reine Funktion, deterministisch (Gleichstand: Schlüssel)
public enum AutoMix {
    /// Bewertung eines Kandidaten gegen den Bezug (kleiner = besser); nil = scheidet aus:
    /// ohne Grid, Tempo außerhalb des Fensters der Match-Regel, Tonart-Konflikt (wenn nicht erlaubt)
    public static func score(_ c: AutoMixCandidate, ref: AutoMixRef, rule: MatchRule, prefs: AutoMixPrefs) -> Double? {
        guard c.hasGrid else { return nil }
        var s = 0.0
        // Tonart: gleich 0, ±1 und relativ 1, Energie-Wechsel 2, Konflikt 8 (nur erlaubt)
        if let rk = ref.key {
            if let ck = c.harmony {
                let rel = Harmony.relation(ck, to: rk)
                switch rel.step {
                case .same: break
                case .adjacent, .relative: s += 1
                case .energy: s += 2
                case .clash:
                    guard prefs.allowKeyClash else { return nil }
                    s += 8
                }
                s += 0.1 * Double(abs(rel.turn))
            } else {
                s += 1.5   // unbekannter Key: nur ein Malus
            }
        }
        // Tempo: Pitch bis zum Bezug innerhalb des Fensters der Match-Regel, je Prozent 0,3
        if ref.bpm > 0 {
            guard let off = rule.tempoOffset(c.bpm, to: ref.bpm), abs(off) <= rule.bpmWindow + 1e-9 else { return nil }
            s += abs(off) * 0.3
        }
        // Gruppen: ähnliche Gruppen (Kick, Bass) je Abweichung 1, gleiche Rolle 0,3
        if !ref.tags.isEmpty, !c.tags.isEmpty {
            for g in groups(rule.similar) {
                if let r = ref.tags.primary[g], let t = c.tags.primary[g], r != t { s += 1 }
            }
            if !ref.tags.roles.isDisjoint(with: c.tags.roles) { s += 0.3 }
        }
        // Quelle: wechseln, wenn die Werte nah beieinander liegen
        if let side = ref.side, c.side == side { s += 0.6 }
        // gleicher Künstler direkt hintereinander: stark abwerten (nur wenn es Alternativen gibt)
        if !c.artist.isEmpty, c.artist == ref.artist { s += 4 }
        if !c.analyzed { s += 0.5 }
        return s
    }

    /// Rangliste aller Kandidaten, die nicht ausscheiden; Gleichstand nach Schlüssel
    public static func ranked(_ pool: [AutoMixCandidate], ref: AutoMixRef, rule: MatchRule, prefs: AutoMixPrefs) -> [AutoMixPick] {
        pool.compactMap { c in score(c, ref: ref, rule: rule, prefs: prefs).map { AutoMixPick(key: c.key, score: $0) } }
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.key < $1.key }
    }

    /// Der nächste Track (nil = keiner passt)
    public static func choose(_ pool: [AutoMixCandidate], ref: AutoMixRef, rule: MatchRule, prefs: AutoMixPrefs) -> AutoMixPick? {
        ranked(pool, ref: ref, rule: rule, prefs: prefs).first
    }

    /// Gruppen aus der Liste („K B“, „K,B“)
    public static func groups(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }
}

/// Zeitplan eines Übergangs auf dem Raster des ausgehenden Tracks (Beats, 0 = Grid-Anker = Phrasenstart)
public enum AutoMixTimeline {
    /// Outro: die letzten 32 Takte eines Tracks gehören dem Ausklang
    public static let outroBeats = 32 * BeatGrid.beatsPerBar

    /// Erste Phrasengrenze strikt nach `now`
    public static func nextBoundary(after now: Double, phraseBeats: Double) -> Double {
        let p = max(BeatGrid.beatsPerBar, phraseBeats)
        return ((now / p).rounded(.down) + 1) * p
    }

    /// Ausstieg: die letzte Phrasengrenze vor dem Outro (32 Takte vor dem Ende), sofern sie nach `now` liegt; sonst die
    /// nächste Grenze nach `now`. nil = der Übergang passt nicht mehr vor das Ende
    public static func outBeat(endBeat: Double, now: Double, phraseBeats: Double, transitionBeats: Double) -> Double? {
        let p = max(BeatGrid.beatsPerBar, phraseBeats)
        let last = ((endBeat - outroBeats) / p).rounded(.down) * p
        if last > now { return last }
        let b = nextBoundary(after: now, phraseBeats: p)
        return b + transitionBeats <= endBeat ? b : nil
    }

    /// Anteil des Übergangs 0…1 zu einer Beat-Position (Start = Phrasengrenze des ausgehenden Tracks)
    public static func progress(beat: Double, start: Double, transitionBeats: Double) -> Double {
        min(1, max(0, (beat - start) / max(1, transitionBeats)))
    }
}

/// EQ- und Filter-Stellung eines Decks im Übergang (dB, Filter −1 Tiefpass … +1 Hochpass, Fader 0…1)
public struct AutoMixLevels: Equatable, Sendable {
    public var low = 0.0
    public var mid = 0.0
    public var high = 0.0
    public var filter = 0.0
    public var fader = 1.0

    public init(low: Double = 0, mid: Double = 0, high: Double = 0, filter: Double = 0, fader: Double = 1) {
        self.low = low; self.mid = mid; self.high = high; self.filter = filter; self.fader = fader
    }

    /// Kill-Stellung des EQ (MixDSP: −40 dB = Kill)
    public static let kill = -40.0
    /// Stellung ohne Übergang
    public static let neutral = AutoMixLevels()

    /// Eingehender Track, p = Anteil des Übergangs: Bass aus, Höhen und Mitten rein, Hochpass fällt; Bass-Tausch bei p = 0,5
    /// (ohne Bass-Tausch erst am Ende)
    public static func incoming(_ p: Double, bassSwap: Bool, filterSweep: Bool) -> AutoMixLevels {
        let x = min(1, max(0, p / 0.5))
        let swap = bassSwap ? 0.5 : 1.0
        return AutoMixLevels(low: p >= swap ? 0 : kill,
                             mid: -6 + 6 * x,
                             high: -12 + 12 * x,
                             filter: filterSweep ? 0.3 * (1 - x) : 0,
                             fader: 1)
    }

    /// Ausgehender Track: Höhen fallen in der ersten Hälfte, Bass-Tausch bei p = 0,5 (Bass aus), in der zweiten Hälfte
    /// Fader zu und Tiefpass-Sweep
    public static func outgoing(_ p: Double, bassSwap: Bool, filterSweep: Bool) -> AutoMixLevels {
        let q = min(1, max(0, (p - 0.5) / 0.5))
        return AutoMixLevels(low: bassSwap && p >= 0.5 ? kill : 0,
                             mid: 0,
                             high: -12 * min(1, max(0, p / 0.5)),
                             filter: filterSweep ? -0.9 * q : 0,
                             fader: 1 - q)
    }
}
