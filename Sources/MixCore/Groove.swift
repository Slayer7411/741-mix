import Foundation

/// Schlagzeug-Spuren des Rasters (16tel)
public enum GrooveLane: Int, CaseIterable, Sendable {
    case kick, snare, closedHat, openHat
}

/// Schläge eines Tracks auf dem 16tel-Raster: je Spur und Schritt die Stärke als Velocity (0 = kein Schlag)
public struct GroovePattern: Equatable, Sendable {
    public static let stepsPerBeat = 4
    public static let stepsPerBar = 16

    /// Länge in 16teln
    public var steps: Int
    /// [Spur][Schritt] -> Velocity 1…127, 0 = leer
    public var hits: [[UInt8]]

    public init(steps: Int) {
        self.steps = max(1, steps)
        hits = [[UInt8]](repeating: [UInt8](repeating: 0, count: self.steps), count: GrooveLane.allCases.count)
    }

    public var beats: Double { Double(steps) / Double(Self.stepsPerBeat) }

    @inline(__always) public func velocity(_ l: GrooveLane, _ s: Int) -> UInt8 { hits[l.rawValue][s] }
    @inline(__always) public func has(_ l: GrooveLane, _ s: Int) -> Bool { hits[l.rawValue][s] > 0 }
    public mutating func set(_ l: GrooveLane, _ s: Int, _ v: UInt8) { hits[l.rawValue][s] = v }

    public func steps(_ l: GrooveLane) -> [Int] { (0..<steps).filter { has(l, $0) } }
    /// Schritte mit einer Hi-Hat (offen oder geschlossen)
    public var hatSteps: Set<Int> { Set((0..<steps).filter { has(.closedHat, $0) || has(.openHat, $0) }) }

    /// gerade Viertel mit Kick (Ersatz ohne erkannte Kick)
    public static func fourOnTheFloor(steps: Int) -> GroovePattern {
        var p = GroovePattern(steps: steps)
        for s in stride(from: 0, to: p.steps, by: stepsPerBeat) { p.set(.kick, s, 110) }
        return p
    }
}

/// Schläge aus dem feinen Spektrum (`WaveSpectrum`, 6 Bänder + Höhen-Dauer je Block) am Beat-Raster:
/// je 16tel der Anstieg der Band-Hüllkurve (Spitze kurz nach dem Schritt gegen das Minimum davor, Pegel nach unten
/// begrenzt, damit Stille keine Riesen-Anstiege liefert).
/// Kick = Sub + Bass; liegen die Kicks auf den Vierteln, zählt neben den Vierteln nur ein gleich lauter Schlag (kein
/// Offbeat-Bass). Snare/Clap = Mitten auf 2 und 4, lauter als die Mitten auf 1 und 3. Hats = Höhen + Air, offen =
/// gehaltene Höhen.
public enum GrooveAnalyzer {
    public struct Settings: Sendable {
        /// Mindest-Anstieg in dB
        public var kickRise: Float = 6
        public var snareRise: Float = 4
        public var hatRise: Float = 3
        /// … und relativ zum stärksten Anstieg der Spur im Bereich
        public var kickRelative: Float = 0.45
        public var hatRelative: Float = 0.35
        /// Kick: Spitze höchstens so weit unter dem Bezugspegel (95. Perzentil der Umgebung)
        public var floorDb: Float = 18
        /// Hats / Mitten: Spitze höchstens so weit unter dem lautesten Bezug (meist Kick + Bass)
        public var hatFloorDb: Float = 36
        public var midFloorDb: Float = 30
        /// Pegel unter (lautester Bezug − silenceDb) gelten als dieser Wert
        public var silenceDb: Float = 45
        /// Kick neben den Vierteln: höchstens so viel leiser als die Viertel-Kicks
        public var offKickDb: Float = 2
        /// Snare: Mitten-Spitze auf 2 / 4 über der auf 1 / 3
        public var snareOverDb: Float = 3
        /// Höhen-Dauer (0…1) ab der eine Hat als offen gilt
        public var openSustain: Float = 0.45
        public init() {}
    }

    /// Anstieg (dB) und Spitze (dBFS) einer Bandgruppe an einem Schritt
    public struct Onset: Sendable { public var rise: Float = 0, peak: Float = -160 }
    /// Messung je Schritt: Kick (Sub + Bass), Mitten, Hats (Höhen + Air), Höhen-Dauer 0…1
    public struct Step: Sendable { public var kick = Onset(), mid = Onset(), hat = Onset(), sustain: Float = 0 }
    /// Bezugspegel je Gruppe (95. Perzentil)
    public struct Reference: Sendable {
        public var kick: Float, mid: Float, hat: Float
        public var loudest: Float { max(kick, mid, hat) }
    }

    static func sum(_ a: Float, _ b: Float) -> Float { 10 * log10f(powf(10, a / 10) + powf(10, b / 10)) }

    /// Bezug aus der Umgebung des Bereichs (±`span` Blöcke) – ganzer Track wäre teurer und mischt Intro / Breaks hinein
    public static func reference(_ s: WaveSpectrum, around a: Int, _ b: Int, span: Int) -> Reference {
        let lo = max(0, min(a, b) - span), hi = min(s.count, max(a, b) + span)
        let part = hi > lo ? WaveSpectrum(data: Array(s.data[lo * WaveSpectrum.stride..<hi * WaveSpectrum.stride])) : s
        let r = part.reference()
        return Reference(kick: sum(r[0], r[1]), mid: sum(r[2], r[3]), hat: sum(r[4], r[5]))
    }

    /// `floor`: Pegel darunter zählen als `floor` (dBFS)
    public static func measure(_ s: WaveSpectrum, blocksPerSecond bps: Double, grid: BeatGrid, startBeat: Double, steps: Int,
                               floor: Float = -160) -> [Step] {
        let n = s.count
        guard n > 0, bps > 0, grid.bpm > 0 else { return [Step](repeating: Step(), count: steps) }
        let stepSec = grid.beat / Double(GroovePattern.stepsPerBeat)
        // Fenster in Blöcken: Spitze 10 ms vor bis 35 % des Schritts danach, Minimum ab 60 % des Schritts davor
        let peakPre = max(1, Int((0.010 * bps).rounded())), peakPost = max(2, Int((min(0.035, stepSec * 0.35) * bps).rounded()))
        let basePre = max(3, Int((min(0.07, stepSec * 0.6) * bps).rounded())), baseGap = max(1, Int((0.012 * bps).rounded()))
        let susLen = max(2, Int((min(0.06, stepSec * 0.5) * bps).rounded()))

        func level(_ i: Int, _ a: WaveSpectrum.Band, _ b: WaveSpectrum.Band) -> Float {
            // vor dem Anfang / nach dem Ende: Stille
            guard i >= 0, i < n else { return floor }
            return max(floor, sum(s.level(i, a), s.level(i, b)))
        }
        func onset(_ center: Int, _ a: WaveSpectrum.Band, _ b: WaveSpectrum.Band) -> Onset {
            var pk: Float = -160
            for i in (center - peakPre)...(center + peakPost) { pk = max(pk, level(i, a, b)) }
            var base = pk
            for i in (center - basePre)...(center - baseGap) { base = min(base, level(i, a, b)) }
            return Onset(rise: max(0, pk - base), peak: pk)
        }
        return (0..<steps).map { st in
            let t = grid.time(ofBeat: startBeat + Double(st) / Double(GroovePattern.stepsPerBeat))
            let center = Int((t * bps).rounded())
            guard center >= 0, center < n else { return Step() }
            var a: Float = 0
            for i in center..<min(n, center + susLen) { a += s.sustain(i) }
            return Step(kick: onset(center, .sub, .bass), mid: onset(center, .lowMid, .highMid), hat: onset(center, .high, .air),
                        sustain: a / Float(min(n, center + susLen) - center))
        }
    }

    static func median(_ v: [Float]) -> Float? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s[s.count / 2]
    }

    /// `startBeat` = Beat-Position (Grid) von Schritt 0, `beats` = Länge des Bereichs
    public static func extract(_ s: WaveSpectrum, blocksPerSecond bps: Double, grid: BeatGrid, startBeat: Double, beats: Double,
                               settings c: Settings = Settings()) -> GroovePattern {
        let steps = max(1, Int((beats * Double(GroovePattern.stepsPerBeat)).rounded()))
        var p = GroovePattern(steps: steps)
        guard s.count > 0, bps > 0, grid.bpm > 0 else { return .fourOnTheFloor(steps: steps) }
        let a = Int((grid.time(ofBeat: startBeat) * bps).rounded()), b = Int((grid.time(ofBeat: startBeat + beats) * bps).rounded())
        let ref = reference(s, around: a, b, span: Int(30 * bps))
        let m = measure(s, blocksPerSecond: bps, grid: grid, startBeat: startBeat, steps: steps, floor: ref.loudest - c.silenceDb)

        func vel(_ o: Onset, rise thr: Float, ref: Float) -> UInt8 {
            // Anstieg (0…18 dB über der Schwelle) und Pegel zum Bezug je zur Hälfte
            let r = min(1, max(0, (o.rise - thr) / 18)), l = min(1, max(0, (o.peak - ref + 18) / 18))
            return UInt8(max(1, min(127, (40 + 87 * (0.5 * r + 0.5 * l)).rounded())))
        }
        let quarter = GroovePattern.stepsPerBeat, half = GroovePattern.stepsPerBar / 2

        // Kick
        let maxKick = m.map(\.kick.rise).max() ?? 0
        var kicks = (0..<steps).filter {
            let k = m[$0].kick
            return k.rise >= c.kickRise && k.rise >= maxKick * c.kickRelative && k.peak >= ref.kick - c.floorDb
        }
        let onQuarters = kicks.filter { $0 % quarter == 0 }
        if onQuarters.count * 4 >= (steps + quarter - 1) / quarter * 3, let q = median(onQuarters.map { m[$0].kick.peak }) {
            // gerade Kick: daneben nur, was so laut ist wie sie (Offbeat-Bass bleibt draußen)
            kicks = kicks.filter { $0 % quarter == 0 || m[$0].kick.peak >= q - c.offKickDb }
        }
        for st in kicks { p.set(.kick, st, vel(m[st].kick, rise: c.kickRise, ref: ref.kick)) }

        // Snare / Clap: nur auf 2 und 4, Mitten lauter als auf 1 und 3 oder deutlich stärker ansteigend
        let one = (0..<steps).filter { $0 % half == 0 }
        if let basePeak = median(one.map { m[$0].mid.peak }), let baseRise = median(one.map { m[$0].mid.rise }) {
            for st in 0..<steps where st % half == quarter {
                let o = m[st].mid
                guard o.peak >= ref.loudest - c.midFloorDb, o.rise >= c.snareRise else { continue }
                if o.peak - basePeak >= c.snareOverDb || o.rise - baseRise >= c.snareOverDb + 3 {
                    p.set(.snare, st, vel(o, rise: c.snareRise, ref: ref.mid))
                }
            }
        }

        // Hats; auf einer Snare nur, wenn die Höhen deutlich stärker ansteigen als die Mitten
        let maxHat = m.map(\.hat.rise).max() ?? 0
        for st in 0..<steps {
            let h = m[st].hat
            guard h.rise >= c.hatRise, h.rise >= maxHat * c.hatRelative, h.peak >= ref.loudest - c.hatFloorDb else { continue }
            if p.has(.snare, st), h.rise < m[st].mid.rise + 6 { continue }
            p.set(m[st].sustain >= c.openSustain ? .openHat : .closedHat, st, vel(h, rise: c.hatRise, ref: ref.hat))
        }
        return p
    }
}

// MARK: - Generator

/// was erzeugt wird
public enum GrooveInstrument: String, CaseIterable, Codable, Sendable {
    case hats, bass, both
}

/// Rhythmus: `tight` nur auf den Kicks (Hats: Offbeats), `off` Offbeat, `rolling` 16tel
public enum GrooveStyle: String, CaseIterable, Codable, Sendable {
    case tight, off, rolling
}

/// eine Note im Raster (Start und Länge in 16teln, Kanal 0…15)
public struct GrooveNote: Equatable, Sendable {
    public var step: Int
    public var length: Double
    public var channel: UInt8
    public var note: UInt8
    public var velocity: UInt8
    public init(step: Int, length: Double, channel: UInt8, note: UInt8, velocity: UInt8) {
        self.step = step; self.length = length; self.channel = channel; self.note = note; self.velocity = velocity
    }
}

/// erzeugtes Muster (Loop über `steps` 16tel)
public struct GrooveClip: Equatable, Sendable {
    public var steps: Int
    public var notes: [GrooveNote]
    public init(steps: Int, notes: [GrooveNote]) { self.steps = steps; self.notes = notes }
    public var beats: Double { Double(steps) / Double(GroovePattern.stepsPerBeat) }
    public func notes(channel: UInt8) -> [GrooveNote] { notes.filter { $0.channel == channel } }
}

/// deterministische Zufallsfolge (SplitMix64)
public struct GrooveRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x741_741 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// 0 ..< 1
    public mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    public mutating func chance(_ p: Double) -> Bool { unit() < p }
    public mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
}

/// Regeln für Hats und Bass zum erkannten Muster (kein ML, gleicher Seed = gleiches Ergebnis)
public enum GrooveGenerator {
    /// General MIDI Schlagzeug
    public static let kickNote: UInt8 = 36, snareNote: UInt8 = 38, closedHatNote: UInt8 = 42, openHatNote: UInt8 = 46

    public struct Options: Equatable, Sendable {
        public var instrument = GrooveInstrument.both
        public var style = GrooveStyle.off
        public var seed: UInt64 = 0
        /// Tonart wie MUSICAL_KEY (0–11 Dur, 12–23 Moll), nil = A-Moll
        public var key: Int?
        /// hörbare Verschiebung in Halbtönen (Key-Shift, Tempo ohne Keylock)
        public var transpose = 0
        /// Oktave des Grundtons (C3 = 60): 1 -> C1 = 36
        public var bassOctave = 1
        /// Kanäle 0-basiert (0 = Kanal 1, 9 = Kanal 10)
        public var bassChannel: UInt8 = 0
        public var drumChannel: UInt8 = 9
        public init() {}
    }

    /// MIDI-Note des Grundtons: Tonart (+ Verschiebung) in der Oktave (C3 = 60)
    public static func rootNote(key: Int?, transpose: Int = 0, octave: Int) -> UInt8 {
        let pc = ((key.map { $0 % 12 } ?? 9) + transpose % 12 + 24) % 12
        return UInt8(max(0, min(127, 12 * (octave + 2) + pc)))
    }

    public static func clip(_ p: GroovePattern, _ o: Options) -> GrooveClip {
        var notes = [GrooveNote]()
        if o.instrument != .bass {
            for h in hats(p, style: o.style, seed: o.seed) {
                notes.append(GrooveNote(step: h.step, length: h.open ? 1.5 : 0.5, channel: o.drumChannel,
                                        note: h.open ? openHatNote : closedHatNote, velocity: h.velocity))
            }
        }
        if o.instrument != .hats {
            notes += bass(p, style: o.style, seed: o.seed, root: rootNote(key: o.key, transpose: o.transpose, octave: o.bassOctave),
                          minor: o.key.map(Harmony.isMinor) ?? true, channel: o.bassChannel)
        }
        notes.sort { ($0.step, $0.channel, $0.note) < ($1.step, $1.channel, $1.note) }
        return GrooveClip(steps: p.steps, notes: notes)
    }

    /// Hats, die das vorhandene Muster ergänzen: nur auf freien 16teln (keine Doppelung einer Hat im Track).
    /// tight: Offbeats · off: Offbeats + offene Hat auf dem letzten Offbeat des Takts + einzelne 16tel · rolling: alle 16tel
    public static func hats(_ p: GroovePattern, style: GrooveStyle, seed: UInt64) -> [(step: Int, open: Bool, velocity: UInt8)] {
        var rng = GrooveRandom(seed: seed &* 31 &+ 1)
        let taken = p.hatSteps
        var out = [(step: Int, open: Bool, velocity: UInt8)]()
        func vel(_ base: Int, _ spread: Int) -> UInt8 { UInt8(max(1, min(127, base + rng.int(-spread...spread)))) }
        // je Takt: zweiter Takt darf eine eigene offene Hat bekommen (Seed)
        let openAlso6 = rng.chance(0.35), ghostCount = rng.int(1...2), ghostShift = rng.int(0...3)
        for st in 0..<p.steps where !taken.contains(st) {
            let inBar = st % GroovePattern.stepsPerBar, sixteenth = st % 2 == 1, offbeat = st % 4 == 2
            let lastOff = inBar == 14 || (p.steps < GroovePattern.stepsPerBar && st == p.steps - 2)
            switch style {
            case .tight:
                if offbeat { out.append((st, false, vel(100, 6))) }
            case .off:
                if offbeat {
                    let open = lastOff || (openAlso6 && inBar == 6 && st >= GroovePattern.stepsPerBar)
                    out.append((st, open, open ? vel(96, 4) : vel(104, 6)))
                } else if sixteenth, (inBar / 2 + ghostShift) % 8 < ghostCount, !p.has(.kick, st) {
                    out.append((st, false, vel(62, 8)))
                }
            case .rolling:
                if offbeat { out.append((st, lastOff && rng.chance(0.7), vel(108, 5))) }
                else if sixteenth { out.append((st, false, vel(rng.chance(0.25) ? 82 : 66, 8))) }
                else { out.append((st, false, vel(74, 6))) }
            }
        }
        // alles schon belegt (z. B. Offbeat-Hats im Track): leise 16tel in die Lücken
        if out.isEmpty {
            for st in 0..<p.steps where !taken.contains(st) && st % 2 == 1 { out.append((st, false, vel(58, 6))) }
        }
        return out
    }

    /// Bass aus den Kick-Positionen: tight = mit der Kick, off = Offbeat nach der Kick, rolling = 16tel zwischen den Kicks.
    /// Grundton aus der Tonart, Quinte / Oktave als Variation (Seed), Länge bis zur nächsten Note (85 %)
    public static func bass(_ p: GroovePattern, style: GrooveStyle, seed: UInt64, root: UInt8, minor: Bool, channel: UInt8) -> [GrooveNote] {
        var rng = GrooveRandom(seed: seed &* 131 &+ 7)
        var kicks = p.steps(.kick)
        if kicks.isEmpty { kicks = Array(stride(from: 0, to: p.steps, by: GroovePattern.stepsPerBeat)) }
        let kickSet = Set(kicks)
        var steps = Set<Int>()
        for (i, k) in kicks.enumerated() {
            let next = i + 1 < kicks.count ? kicks[i + 1] : kicks[0] + p.steps
            switch style {
            case .tight:
                steps.insert(k)
            case .off:
                // Offbeat zwischen zwei Kicks; bei weitem Abstand (Seed) noch eine 16tel danach
                let gap = next - k
                let at = gap >= 4 ? k + 2 : k + max(1, gap / 2)
                if at < next { steps.insert(at % p.steps) }
                if gap >= 4, rng.chance(0.25), k + 3 < next { steps.insert((k + 3) % p.steps) }
            case .rolling:
                var s = k + 1
                while s < next {
                    if !(s == k + 1 && rng.chance(0.2)) { steps.insert(s % p.steps) }
                    s += 1
                }
            }
        }
        if style != .tight { steps.subtract(kickSet) }
        if steps.isEmpty { steps = Set(kicks) }
        let sorted = steps.sorted()
        // Tonhöhen: erster Takt würfelt, zweiter wiederholt ihn und variiert die letzten Noten (Turnaround)
        let bar = GroovePattern.stepsPerBar
        var pitch = [Int: Int]()
        func roll() -> Int {
            let u = rng.unit()
            return u < 0.68 ? 0 : (u < 0.84 ? 12 : (u < 0.96 ? 7 : (minor ? 3 : 4)))
        }
        for s in sorted where s < bar { pitch[s] = s == sorted.first ? 0 : roll() }
        let tail = Set(sorted.filter { $0 >= bar }.suffix(rng.int(1...2)))
        for s in sorted where s >= bar { pitch[s] = tail.contains(s) ? roll() : (pitch[s - bar] ?? roll()) }
        var out = [GrooveNote]()
        for (i, s) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + p.steps
            let len = max(0.5, Double(next - s) * 0.85)
            let accent = s % 4 == 2 ? 112 : (s % 4 == 0 ? 100 : 88)
            let v = UInt8(max(1, min(127, accent + rng.int(-6...6))))
            let n = Int(root) + (pitch[s] ?? 0)
            out.append(GrooveNote(step: s, length: len, channel: channel, note: UInt8(max(0, min(127, n))), velocity: v))
        }
        return out
    }
}

// MARK: - Planung im Takt der Clock

/// Noten des Clips auf die laufende Clock legen: liefert für ein Fenster [jetzt, jetzt + Vorlauf) die Ereignisse in
/// Clock-Beats. Schritt 0 des Clips liegt auf `origin` (+ Vielfache der Clip-Länge). Note-Offs warten, bis sie ins
/// Fenster fallen (keine Ereignisse weit in der Zukunft). Springt die Clock (> 1 Beat), beginnt die Planung neu.
public struct GrooveSchedule: Sendable {
    public struct Event: Equatable, Sendable {
        public var beat: Double
        /// 0x90 / 0x80 | Kanal
        public var status: UInt8
        public var note: UInt8
        public var velocity: UInt8
        public var isOn: Bool { status & 0xF0 == 0x90 }
    }

    public var clip: GrooveClip
    public var origin: Double
    /// bis hierher geplant (exklusiv)
    public private(set) var planned: Double?
    private var offs: [Event] = []

    public init(clip: GrooveClip, origin: Double) { self.clip = clip; self.origin = origin }

    /// laufende Noten (für das Anhalten)
    public var pendingOffs: Int { offs.count }

    public mutating func events(now: Double, ahead: Double) -> [Event] {
        let to = now + max(0, ahead)
        var from = planned ?? now
        var out = [Event]()
        if abs(from - now) > 1 || from > to {
            // Clock gesprungen: hängende Noten jetzt beenden, ab jetzt neu planen
            out += offs.map { var e = $0; e.beat = now; return e }
            offs.removeAll()
            from = now
        }
        let loop = clip.beats
        if loop > 0, to > from {
            for n in clip.notes {
                let sb = Double(n.step) / Double(GroovePattern.stepsPerBeat)
                var x = origin + sb + ((from - origin - sb) / loop).rounded(.up) * loop
                if x < from { x += loop }
                while x < to {
                    let ch = n.channel & 0x0F
                    // gleiche Note noch an: vorher beenden
                    if let i = offs.firstIndex(where: { $0.status == 0x80 | ch && $0.note == n.note }) {
                        var e = offs.remove(at: i); e.beat = min(e.beat, x); out.append(e)
                    }
                    out.append(Event(beat: x, status: 0x90 | ch, note: n.note, velocity: max(1, n.velocity)))
                    offs.append(Event(beat: x + n.length / Double(GroovePattern.stepsPerBeat), status: 0x80 | ch, note: n.note, velocity: 0))
                    x += loop
                }
            }
        }
        offs.sort { $0.beat < $1.beat }
        while let f = offs.first, f.beat < to { out.append(offs.removeFirst()) }
        planned = max(to, from)
        // Offs vor Ons bei gleichem Beat
        out.sort { $0.beat != $1.beat ? $0.beat < $1.beat : (!$0.isOn && $1.isOn) }
        return out
    }

    /// alles beenden (Stopp): alle offenen Noten jetzt
    public mutating func flush(now: Double) -> [Event] {
        let out = offs.map { var e = $0; e.beat = now; return e }
        offs.removeAll()
        planned = nil
        return out
    }
}
