import Foundation

/// Amplify: Lautstärke einer Datei rein linear anheben (Samples × Faktor), kein Limiter, kein Kompressor.
/// Spitze und Headroom in dBFS; ohne „Clipping erlauben“ höchstens bis 0 dBFS
public enum Amplify {
    /// NORM: Spitze genau hier (dBFS)
    public static let normTarget = -0.3
    /// Schritte der AMP-Knöpfe (dB)
    public static let steps: [Double] = [1, 3, 6]

    public static func factor(db: Double) -> Double { pow(10, db / 20) }
    public static func db(factor: Double) -> Double { 20 * log10(max(factor, 1e-12)) }

    /// Spitze (linear) in dBFS; Stille = −∞
    public static func dbfs(peak: Float) -> Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }

    /// Abstand der Spitze zu 0 dBFS (dB), Stille = +∞
    public static func headroom(peak: Float) -> Double { -dbfs(peak: peak) }

    /// NORM: Gain, der die Spitze auf `normTarget` bringt (negativ, wenn sie schon darüber liegt); Stille = 0
    public static func normGain(peak: Float, target: Double = normTarget) -> Double {
        peak > 0 ? target - dbfs(peak: peak) : 0
    }

    /// gewünschter Gain -> erlaubter: nie unter 0 (nur anheben), ohne `allowClipping` höchstens bis 0 dBFS.
    /// `limited` = der Wunsch ging über den Headroom
    public static func limit(_ db: Double, peak: Float?, allowClipping: Bool) -> (db: Double, limited: Bool) {
        let want = max(0, db)
        guard !allowClipping, let p = peak, p > 0 else { return (want, false) }
        let room = max(0, headroom(peak: p))
        return want > room + 1e-9 ? (room, true) : (want, false)
    }

    /// Faktor so, dass `peak · f` 1.0 nicht überschreitet (Rundung in Float)
    public static func safeFactor(_ db: Double, peak: Float) -> Float {
        var f = Float(factor(db: db))
        while peak > 0, peak * f > 1 { f = f.nextDown }
        return f
    }

    /// Samples × Faktor; `clamp` = auf ±1 begrenzen (Clipping erlaubt: hart, sonst kommt es nie vor)
    public static func apply(_ p: UnsafeMutablePointer<Float>, count: Int, factor f: Float, clamp: Bool) {
        guard f != 1 || clamp else { return }
        for i in 0..<max(0, count) {
            let v = p[i] * f
            p[i] = clamp ? min(1, max(-1, v)) : v
        }
    }

    /// „+3“, „+4.2“ (eine Stelle, ganze Zahlen ohne)
    public static func label(_ db: Double) -> String {
        let r = (db * 10).rounded() / 10
        let s = abs(r - r.rounded()) < 1e-9 ? String(Int(r.rounded())) : String(format: "%.1f", r)
        return r > 0 ? "+" + s : (r < 0 ? s.replacingOccurrences(of: "-", with: "−") : s)
    }

    /// Lautheit der neuen Datei: PERCEIVED_DB ist der Gain zur Referenz (lauter -> kleiner), PEAK_DB der Abstand der
    /// Spitze zu 0 dBFS (lauter -> kleiner); gemessene Spitze der neuen Datei, wenn bekannt
    public static func loudness(_ t: inout Track, gain db: Double, peak: Float?) {
        if let p = t.perceivedDb { t.perceivedDb = p - db }
        if let p = peak, p > 0 { t.peakDb = headroom(peak: p) } else if let p = t.peakDb { t.peakDb = p - db }
    }
}

/// AMP-Einstellung der Werkzeugzeile: fester Gain oder NORM (Gain aus der Spitze beim Rendern)
public enum AmpRequest: Equatable, Sendable {
    case db(Double)
    case norm

    /// Gain für eine Spitze (NORM nie unter 0: nur anheben)
    public func gain(peak: Float) -> Double {
        switch self {
        case let .db(v): max(0, v)
        case .norm: max(0, Amplify.normGain(peak: peak))
        }
    }

    public var isNone: Bool { if case let .db(v) = self { return v <= 1e-9 } else { return false } }
}

/// Dateinamen und Titel der Vorbereiten-Ergebnisse: neue Dateien neben dem Original, das Original bleibt
public enum PrepareName {
    /// Teile eines Namens kürzen (Dateisystem: 255 Bytes)
    static let maxBase = 110

    static func base(_ original: String) -> String {
        let b = (original as NSString).deletingPathExtension
        return b.count > maxBase ? String(b.prefix(maxBase)) : b
    }

    /// „<Name> [tag].ext“, belegt -> „[tag #2]“ usw.
    public static func fileName(_ original: String, tag: String, ext: String = "m4a", taken: (String) -> Bool) -> String {
        name(base(original), tag: tag, ext: ext, taken: taken)
    }

    /// „<Name1> + <Name2> [join].ext“
    public static func joinName(_ a: String, _ b: String, ext: String = "m4a", taken: (String) -> Bool) -> String {
        name(base(a) + " + " + base(b), tag: "join", ext: ext, taken: taken)
    }

    static func name(_ base: String, tag: String, ext: String, taken: (String) -> Bool) -> String {
        for n in 1...9999 {
            let s = base + (n == 1 ? " [\(tag)]" : " [\(tag) #\(n)]") + "." + ext
            if !taken(s) { return s }
        }
        return base + " [\(tag) \(UUID().uuidString.prefix(8))]." + ext
    }

    /// Titel mit Kennung: „<Titel> [tag]“
    public static func title(_ t: String, tag: String) -> String { t.isEmpty ? "[\(tag)]" : t + " [\(tag)]" }

    /// Kennung eines RENDER: Schnitt und / oder Gain („cut“, „amp +3“, „cut amp +3“); nil = nichts zu tun
    public static func renderTag(cut: Bool, gain db: Double) -> String? {
        var parts: [String] = []
        if cut { parts.append("cut") }
        if db > 1e-9 { parts.append("amp " + Amplify.label(db)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// JOIN: zweite Datei ans Ende der ersten, am Grid. Beat-Eins der zweiten (erster Taktanfang in der Datei) landet auf
/// dem nächsten Taktanfang der ersten an oder nach ihrem Ende (dazwischen Stille). Tempo gleich bis ±0,5 % -> die
/// zweite wird angeglichen (Abspieltempo, wenn gewünscht), sonst läuft ihr Raster gegen das der ersten (Hinweis).
/// Das Grid der ersten läuft weiter. Alle Zeiten in Sekunden
public struct JoinPlan: Equatable, Sendable {
    /// Ausgabe-Zeit, an der die zweite beginnt (Taktanfang der ersten)
    public var joint: Double
    /// erste Zeit der zweiten Datei, die gespielt wird (ihre Beat-Eins)
    public var startB: Double
    /// Abspieltempo der zweiten (1 = unverändert; bpmA / bpmB beim Angleichen)
    public var speed: Double
    /// Länge der zweiten Datei (Quelle)
    public var durationB: Double
    /// Tempo verschieden (über ±0,5 %): Raster der zweiten passt nicht zum Grid der ersten
    public var tempoMismatch: Bool
    /// Grid der Ausgabe
    public var grid: BeatGrid?

    /// größte Abweichung, die angeglichen wird
    public static let matchTolerance = 0.005
    /// Ende der ersten so nah vor einem Taktanfang: zählt als darauf (gerundete Dateilängen)
    public static let barSlack = 0.005

    public var duration: Double { joint + max(0, durationB - startB) / speed }

    /// Quelle der zweiten -> Ausgabe-Zeit
    public func outputTime(ofB t: Double) -> Double { joint + (t - startB) / speed }

    public static func plan(durationA: Double, gridA: BeatGrid?, durationB: Double, gridB: BeatGrid?, matchTempo: Bool) -> JoinPlan {
        let ga = gridA.flatMap { $0.bpm > 0 && $0.bpm.isFinite ? $0 : nil }
        let gb = gridB.flatMap { $0.bpm > 0 && $0.bpm.isFinite ? $0 : nil }
        var joint = max(0, durationA)
        if let g = ga {
            let bar = g.beat * BeatGrid.beatsPerBar
            joint = g.anchor + ((durationA - barSlack - g.anchor) / bar).rounded(.up) * bar
            joint = max(joint, 0)
        }
        var startB = 0.0
        if let g = gb {
            let bar = g.beat * BeatGrid.beatsPerBar
            startB = g.anchor - ((g.anchor + 1e-9) / bar).rounded(.down) * bar
            if startB >= durationB { startB = 0 }
        }
        var speed = 1.0, mismatch = false
        if let a = ga, let b = gb {
            let dev = abs(a.bpm / b.bpm - 1)
            if dev > matchTolerance { mismatch = true } else if matchTempo, dev > 1e-9 { speed = a.bpm / b.bpm }
        }
        let grid = ga ?? gb.map { BeatGrid(anchor: joint, bpm: $0.bpm * speed) }
        return JoinPlan(joint: joint, startB: startB, speed: speed, durationB: max(0, durationB), tempoMismatch: mismatch, grid: grid)
    }

    /// Cues beider Dateien: die der ersten bleiben (bis zur Naht), die der zweiten ab ihrer Beat-Eins rücken hinter die
    /// Naht (Loops mit angeglichener Länge). Hotcue-Plätze der zweiten, die die erste belegt, gehen auf freie Plätze,
    /// sonst werden es Memory-Cues. Grid-Marker fallen weg (das Grid setzt `track`)
    public func cues(a: [Cue], b: [Cue]) -> [Cue] {
        var out = a.filter { $0.kind != .grid && $0.startMs / 1000 < joint + 1e-6 }
        var used = Set(out.compactMap { $0.hotcue >= 0 ? $0.hotcue : nil })
        for c in b.sorted(by: { ($0.hotcue < 0 ? 99 : $0.hotcue, $0.startMs) < ($1.hotcue < 0 ? 99 : $1.hotcue, $1.startMs) }) {
            let s = c.startMs / 1000
            guard c.kind != .grid, s >= startB - 1e-6 else { continue }
            var n = c
            n.startMs = outputTime(ofB: s) * 1000
            if n.kind == .loop { n.lengthMs = c.lengthMs / speed }
            if n.hotcue >= 0, used.contains(n.hotcue) { n.hotcue = (0..<8).first { !used.contains($0) } ?? -1 }
            if n.hotcue >= 0 { used.insert(n.hotcue) }
            out.append(n)
        }
        return out
    }

    /// Track der Ausgabe: Metadaten der ersten, Titel „A + B [join]“, Grid der ersten, Cues beider
    public func track(a: Track, b: Track, key: String, path: String, cuesA: [Cue], cuesB: [Cue], duration: Double,
                      now: Date = Date()) -> Track {
        var n = a
        n.key = key
        n.path = path
        let ta = a.title.isEmpty ? (a.fileName as NSString).deletingPathExtension : a.title
        let tb = b.title.isEmpty ? (b.fileName as NSString).deletingPathExtension : b.title
        n.title = PrepareName.title(ta + " + " + tb, tag: "join")
        n.duration = duration
        n.importDate = now
        n.playCount = 0
        n.lastPlayed = nil
        n.loose = false
        n.fileMissing = false
        n.ownAnalysis = false
        var cues = self.cues(a: cuesA, b: cuesB)
        if let g = grid {
            n.bpm = g.bpm
            cues.insert(Cue(name: "Grid", kind: .grid, startMs: g.anchor * 1000, lengthMs: 0, hotcue: -1), at: 0)
        }
        n.cues = cues
        n.buildSearchText()
        return n
    }
}

/// SPLIT: an einer Marke (Taktanfang) in zwei Dateien. Beide Teile sind Schnittlisten der gespielten Liste
public enum SplitPlan {
    /// Teilungspunkt: Bereichsanfang, sonst der Taktanfang am nächsten zur Position; nil = Teile zu kurz
    public static func point(range: TrackRange?, position: Double, grid: BeatGrid?, duration: Double) -> Double? {
        var t = range?.start ?? position
        if range == nil { t = TrackRange.snap(t, grid: grid, step: BeatGrid.beatsPerBar, free: false, duration: duration) }
        let min = TrackTrim.minLength
        return t >= min - 1e-9 && t <= duration - min + 1e-9 ? t : nil
    }

    /// Teil 1 = bis t, Teil 2 = ab t (Ausgabe-Zeit der Liste)
    public static func parts(_ e: EditList, at t: Double) -> (EditList, EditList)? {
        var a = e, b = e
        guard a.keep(TrackRange(0, t)), b.keep(TrackRange(t, e.duration)) else { return nil }
        return (a, b)
    }

    public static func tag(_ n: Int) -> String { "part \(n)" }
}
