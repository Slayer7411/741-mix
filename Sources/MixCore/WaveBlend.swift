import Foundation

/// Daten des Stils „3-Band (Mischung)“ je Wellenform-Block, 8 Bytes: Effektivwert des Mono-Signals, die gewichteten
/// Band-Hüllkurven Tief / Mitte / Hoch im Mittel über den Block und am lautesten Sample des Blocks.
/// Pegel in 0,5-dB-Schritten wie `WaveSpectrum` (255 = 0 dBFS, 0 = Stille). 10 min ≈ 1,4 MB.
public struct WaveBlend: Equatable, Sendable {
    public static let stride = 8
    public static let rmsSlot = 0, meanSlot = 1, peakSlot = 4

    public var data: [UInt8]
    public init(data: [UInt8]) { self.data = data }
    public static let empty = WaveBlend(data: [])

    public var count: Int { data.count / Self.stride }

    /// Amplitude → Byte (0,5 dB je Schritt, −127 dBFS … 0 dBFS)
    @inline(__always) public static func byte(amplitude a: Float) -> UInt8 {
        guard a > 4.5e-7 else { return 0 }
        return UInt8(max(1, min(255, (255 + 40 * log10f(a)).rounded())))
    }

    /// Byte → Amplitude (Tabelle)
    public static let amplitude: [Float] = (0..<256).map { $0 == 0 ? 0 : powf(10, (Float($0) - 255) / 40) }
}

/// Rasterung des Mischungs-Stils: je Pixelspalte und -zeile Deckung (Anteil der Samples, die die Zeile erreichen) und
/// Farbe aus den Band-Hüllkurven der Samples, die diese Zeile erreichen. Die Höhe und die Deckung kommen aus den Blöcken
/// der Spalte selbst, die Farbe aus einem Fenster von Nachbarblöcken (`Palette.window`): eine Zeile oberhalb des
/// Körpers erreichen nur die lauten Blöcke der Umgebung (Transienten, Hats, Kick-Anschlag), deren Hüllkurven färben
/// die Spitzen – der Körper bleibt beim Bass. Unten (bis zum Effektivwert) deckt ein Block voll, darüber fällt die
/// Deckung linear bis zur Spitze. Helligkeit = Deckung^(1/3,5).
public enum BlendPaint {
    public typealias RGB = (r: Float, g: Float, b: Float)

    /// Exponent der Helligkeit über der Deckung (weich nach oben auslaufend)
    public static let gamma: Float = 1 / 3.5
    /// Grundpegel im Nenner der Bandanteile: leise Stellen werden dunkler statt voll gesättigt
    public static let floor: Float = 0.01
    /// Exponent auf die Bandanteile der RGB-Palette (> 1: das stärkste Band setzt sich in der Farbe durch)
    public static let saturation: Float = 1.5
    /// Farbfenster: Nachbarblöcke je Seite (Blöcke à 1/300 s → 1 = ±3 ms, glättet Anschläge über die Nachbarspalte)
    public static let window = 1
    /// Band-Gewichte zur Renderzeit (Tief, Mitte, Hoch) auf die analysierten Hüllkurven: Mitten zurück (Analyse hebt den
    /// Bandpass ×1,4 an), Höhen vor – Hats und Transienten sollen als blaue Spitzen sichtbar sein
    public static let gain: RGB = (1, 0.55, 1.6)

    /// Palette: `direct` = Bandanteile direkt als Rot / Grün / Blau, sonst drei Farben (Tief, Mitte, Hoch), Höhen
    /// quadratisch (nur starke Höhen färben)
    public struct Palette: Sendable {
        public var low: RGB, mid: RGB, high: RGB
        /// Farbe gehaltener Höhen (offene Hats, Ride): hellblau statt blau; Anteil je Block aus der Höhen-Dauer des Spektrums
        public var highOpen: RGB
        /// Farbe gehaltener Tiefen (Bassline, Sub-Ausklang): orange statt rot; Anteil je Block aus `warmth`
        public var lowWarm: RGB
        public var direct: Bool
        /// Anteil der Höhen in der Mischung (1 = voll)
        public var highShare: Float
        /// Exponent auf die Bandanteile (nur `direct`)
        public var saturation: Float
        /// Farbfenster in Blöcken je Seite
        public var window: Int
        /// Band-Gewichte Tief / Mitte / Hoch auf die gespeicherten Hüllkurven (1 = wie analysiert)
        public var gain: RGB
        /// Anteil der Energie-Mischung an der Farbe (Tönung), Rest aus dem Stapel-Abschnitt; 1 = keine Stapel
        public var base: Float = BlendPaint.base
        /// Breite der Übergänge zwischen den gestapelten Bändern (Anteil der Blockspitze)
        public var fade: Float = BlendPaint.fade
        /// Exponent auf die gewichteten Band-Spitzen für die Stapel-Abschnitte (< 1: leise Bänder bekommen sichtbar Höhe)
        public var stackCurve: Float = BlendPaint.stackCurve
        /// Stärke der Orange-Tönung gehaltener Tiefen (0 = aus)
        public var warmth: Float = 1
        /// Stärke der Hellblau-Tönung gehaltener Höhen (0 = aus)
        public var openness: Float = 1
        public init(low: RGB, mid: RGB, high: RGB, highOpen: RGB? = nil, lowWarm: RGB? = nil, direct: Bool = false, highShare: Float = 1,
                    saturation: Float = BlendPaint.saturation, window: Int = BlendPaint.window, gain: RGB = BlendPaint.gain) {
            self.low = low; self.mid = mid; self.high = high; self.direct = direct; self.highShare = highShare
            self.highOpen = highOpen ?? (high.r + (1 - high.r) * 0.5, high.g + (1 - high.g) * 0.5, high.b + (1 - high.b) * 0.5)
            let o = BlendPaint.warmOrange
            self.lowWarm = lowWarm ?? (low.r + (o.r - low.r) * 0.5, low.g + (o.g - low.g) * 0.5, low.b + (o.b - low.b) * 0.5)
            self.saturation = saturation; self.window = window; self.gain = gain
        }
        public static let rgb = Palette(low: (1, 0, 0), mid: (0, 1, 0), high: (0, 0, 1), highOpen: BlendPaint.openBlue,
                                        lowWarm: BlendPaint.warmOrange, direct: true)
    }

    /// Versuchswerte für Bilder: "sat,win,gl,gm,gh,base,fade,stack,warm,open" (leere Felder = Standard)
    public struct Tune: Sendable {
        public var saturation: Float?, window: Int?, gain: (Float?, Float?, Float?)
        public var base: Float?, fade: Float?, stackCurve: Float?, warmth: Float?, openness: Float?
        public init?(_ spec: String) {
            let f = spec.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard !f.isEmpty else { return nil }
            func at(_ i: Int) -> Float? { f.count > i ? Float(f[i]) : nil }
            saturation = at(0)
            window = f.count > 1 ? Int(f[1]) : nil
            gain = (at(2), at(3), at(4))
            base = at(5); fade = at(6); stackCurve = at(7); warmth = at(8); openness = at(9)
        }
        public func apply(to p: inout Palette) {
            if let saturation { p.saturation = saturation }
            if let window { p.window = window }
            p.gain = (gain.0 ?? p.gain.r, gain.1 ?? p.gain.g, gain.2 ?? p.gain.b)
            if let base { p.base = base }
            if let fade { p.fade = fade }
            if let stackCurve { p.stackCurve = stackCurve }
            if let warmth { p.warmth = warmth }
            if let openness { p.openness = openness }
        }
        public var label: String {
            "sat \(saturation.map { String(format: "%.1f", $0) } ?? "-") win \(window.map(String.init) ?? "-") gain \(gain.0 ?? 1)/\(gain.1 ?? 1)/\(gain.2 ?? 1)"
            + " base \(base ?? BlendPaint.base) fade \(fade ?? BlendPaint.fade) stack \(stackCurve ?? BlendPaint.stackCurve) warm \(warmth ?? 1) open \(openness ?? 1)"
        }
    }

    /// Helligkeit (Deckung 0…1 → 0…1), 1024 Stufen
    static let lift: [Float] = (0...1024).map { powf(Float($0) / 1024, gamma) }
    @inline(__always) static func brightness(_ c: Float) -> Float { lift[Int(max(0, min(1, c)) * 1024)] }

    /// hellblau gehaltener Höhen in der RGB-Palette (wie `SpectrumColors.open`)
    public static let openBlue: RGB = (0.62, 0.93, 1.0)
    /// orange gehaltener Tiefen in der RGB-Palette (wie `SpectrumColors.sub`)
    public static let warmOrange: RGB = (1.0, 0.5, 0.04)
    /// Fenster des laufenden Minimums für `warmth` (Blöcke à 1/300 s → 300 ms): so lang bleibt ein Kick über dem Pegel
    /// vor seinem Anschlag und damit rot; sein Ausklingen geht in orange über
    public static let warmWindow = 90

    /// Anteil gehaltener Tiefen je Block (0…255): laufendes Minimum der Tief-Spitze über die letzten `window` Blöcke,
    /// geteilt durch die aktuelle Spitze. Ein Kick-Anschlag ragt über das Minimum (Anteil klein → rot), eine Bassline
    /// und der Sub-Ausklang des Kicks liegen darauf (Anteil nahe 1 → orange). Setzt der Kick aus, fehlen die roten
    /// Anschläge. Kick allein: 300 ms rot (ausklingend Richtung orange), dann orange bis zum nächsten Kick.
    public static func warmth(blend: [UInt8], count: Int, window: Int = warmWindow) -> [UInt8] {
        let n = min(count, blend.count / WaveBlend.stride)
        var out = [UInt8](repeating: 0, count: n)
        guard n > 0 else { return out }
        let amp = WaveBlend.amplitude
        @inline(__always) func low(_ i: Int) -> Float { amp[Int(blend[i * WaveBlend.stride + WaveBlend.peakSlot])] }
        var dq: [Int] = []   // Indizes mit steigenden Werten (monotone Schlange), `head` = ältester gültiger
        dq.reserveCapacity(n)
        var head = 0
        for i in 0..<n {
            let v = low(i)
            while dq.count > head, low(dq[dq.count - 1]) >= v { dq.removeLast() }
            dq.append(i)
            if dq[head] <= i - window { head += 1 }
            let m = low(dq[head])
            out[i] = v > 0 ? UInt8(min(255, (m / v * 255).rounded())) : 0
        }
        return out
    }

    /// Spitzen für die Anzeige: Einzelblock-Kerben füllen (Block niedriger als beide Nachbarn → kleinerer Nachbar).
    /// Tiefe Töne lassen die Spitze je 3,3-ms-Block springen; ohne das zeichnet die Wellenform bei 1 Block je Pixel
    /// einen Kamm aus hellen und dunklen Einzelspalten. Einzelne Spitzen (Transienten) bleiben unverändert.
    public static func displayPeaks(_ pk: [Float]) -> [Float] {
        guard pk.count > 2 else { return pk }
        var out = pk
        for k in 1..<(pk.count - 1) { out[k] = max(pk[k], min(pk[k - 1], pk[k + 1])) }
        return out
    }

    /// Pixelfarbe aus den Bandanteilen (Tief, Mitte, Hoch, Summe ≤ 1; kleiner = leiser, dunkler); `open` = Anteil der
    /// Höhen, der gehalten ist (0 = kurze Hats, blau; 1 = offene Hats / Ride, hellblau), `warm` = Anteil der Tiefen, der
    /// gehalten ist (0 = Kick-Anschlag, rot; 1 = Bassline / Sub-Ausklang, orange)
    @inline(__always) public static func paint(_ a: RGB, _ p: Palette, open: Float = 0, warm: Float = 0) -> RGB {
        let a1 = a.r, a2 = a.g, a3 = a.b * p.highShare
        // direkt: Anteile gespreizt und auf das stärkste Band gezogen (klare Farben, Mischungen gelb / cyan / weiß statt
        // trüb), Pegel nahe dem Grundpegel dunkler; gehaltene Höhen ziehen das Blau Richtung hellblau, gehaltene Tiefen
        // das Rot Richtung orange
        if p.direct {
            let b1 = powf(a1, p.saturation), b2 = powf(a2, p.saturation), b3 = powf(a3, p.saturation)
            let g = min(1, a1 + a2 + a3) / max(b1, b2, b3, 1e-6)
            let hb = b3 * g * open, lw = b1 * g * warm
            return (min(1, b1 * g + hb * p.highOpen.r), min(1, b2 * g + hb * p.highOpen.g + lw * p.lowWarm.g), min(1, b3 * g + lw * p.lowWarm.b))
        }
        let k = 1 / (a1 + a2 + floor)
        let w1 = a1 * k, w2 = a2 * k, w3 = a3 * a3
        let hr = p.high.r + (p.highOpen.r - p.high.r) * open, hg = p.high.g + (p.highOpen.g - p.high.g) * open
        let hb = p.high.b + (p.highOpen.b - p.high.b) * open
        let lr = p.low.r + (p.lowWarm.r - p.low.r) * warm, lg = p.low.g + (p.lowWarm.g - p.low.g) * warm
        let lb = p.low.b + (p.lowWarm.b - p.low.b) * warm
        return (min(1, lr * w1 + p.mid.r * w2 + hr * w3),
                min(1, lg * w1 + p.mid.g * w2 + hg * w3),
                min(1, lb * w1 + p.mid.b * w2 + hb * w3))
    }

    /// Farbe aus den summierten Hüllkurven (Tief, Mitte, Hoch) und der Deckungssumme der Zeile – ohne Stapel
    @inline(__always) public static func color(_ e: RGB, weight: Float, _ p: Palette) -> RGB {
        guard weight > 0 else { return (0, 0, 0) }
        let l = e.r * p.gain.r / weight, m = e.g * p.gain.g / weight, h = e.b * p.gain.b / weight
        let s = 1 / (l + m + h + floor)
        return paint((l * s, m * s, h * s), p)
    }

    /// Deckung eines Blocks (Spitze `pk`, Effektivwert `r`) in Zeile `y`
    @inline(__always) static func coverage(_ y: Float, _ pk: Float, _ r: Float) -> Float {
        y > r ? (pk - y) / (pk - r) : 1
    }

    /// Breite der Übergänge zwischen den gestapelten Bändern, Anteil der Blockspitze
    public static let fade: Float = 0.15
    /// Anteil der Energie-Mischung an der Farbe (Tönung des Ganzen), der Rest kommt aus dem Stapel-Abschnitt der Zeile
    public static let base: Float = 0.35
    /// Exponent auf die gewichteten Band-Spitzen für die Stapel-Abschnitte (< 1: leise Bänder bekommen sichtbar Höhe)
    public static let stackCurve: Float = 0.6

    /// weicher Indikator: 1 innerhalb `lo…hi`, linear auf 0 über `f` außerhalb
    @inline(__always) static func inside(_ y: Float, _ lo: Float, _ hi: Float, _ f: Float) -> Float {
        max(0, min(1, (y - lo + f) / f)) * max(0, min(1, (hi - y + f) / f))
    }

    /// Werte eines Blocks für eine Spalte, einmal je Spalte gelesen: Spitze, Effektivwert, gewichtete Band-Spitzen,
    /// Stapel-Anteile, gehaltene Höhen / Tiefen (0…1, mit Stärke der Palette)
    struct Sample {
        var pk: Float, r: Float, gl: Float, gm: Float, gh: Float
        var pl: Float = 0, pm: Float = 0, ph: Float = 0
        var open: Float, warm: Float
        /// Anteil des Blocks an der Spalte (Höhe, Deckung); 0 = nur Farbe aus dem Fenster
        var w: Float
        var own: Bool { w > 0 }

        @inline(__always) mutating func stack(_ p: Palette) {
            pl = powf(gl, p.stackCurve); pm = powf(gm, p.stackCurve); ph = powf(gh, p.stackCurve)
        }

        @inline(__always) static func read(_ k: Int, peak: UnsafeBufferPointer<Float>, blend: UnsafeBufferPointer<UInt8>,
                                           open: UnsafeBufferPointer<UInt8>?, warm: UnsafeBufferPointer<UInt8>?, w: Float, _ p: Palette) -> Sample {
            let amp = WaveBlend.amplitude
            let pk = peak[k], o = k * WaveBlend.stride, t = o + WaveBlend.peakSlot
            var s = Sample(pk: pk, r: min(amp[Int(blend[o])], pk * 0.98),
                           gl: amp[Int(blend[t])] * p.gain.r, gm: amp[Int(blend[t + 1])] * p.gain.g, gh: amp[Int(blend[t + 2])] * p.gain.b,
                           open: open.map { k < $0.count ? Float($0[k]) * (p.openness / 255) : 0 } ?? 0,
                           warm: warm.map { k < $0.count ? Float($0[k]) * (p.warmth / 255) : 0 } ?? 0, w: w)
            s.stack(p)
            return s
        }

        /// linear zwischen zwei Blöcken (f = 0 → a, 1 → b)
        @inline(__always) static func lerp(_ a: Sample, _ b: Sample, _ f: Float, _ p: Palette) -> Sample {
            @inline(__always) func m(_ x: Float, _ y: Float) -> Float { x + (y - x) * f }
            var s = Sample(pk: m(a.pk, b.pk), r: m(a.r, b.r), gl: m(a.gl, b.gl), gm: m(a.gm, b.gm), gh: m(a.gh, b.gh),
                           open: m(a.open, b.open), warm: m(a.warm, b.warm), w: 1)
            s.stack(p)
            return s
        }
    }

    /// Spalte zwischen zwei Block-Mitten: Block `k` und `k + 1`, Anteil `f` des zweiten (Spalte schmaler als ein Block)
    public struct Between: Sendable {
        public var k: Int, f: Float
        public init(k: Int, f: Float) { self.k = k; self.f = f }

        /// Spalte mit der Mitte bei `t` Sekunden, Blöcke à `1 / bps`: die beiden nächsten Block-Mitten
        public static func at(_ t: Double, bps: Double, count n: Int) -> Between {
            let u = t * bps - 0.5
            guard n > 1, u > 0 else { return Between(k: 0, f: 0) }
            let k = Int(u)
            guard k < n - 1 else { return Between(k: n - 1, f: 0) }
            return Between(k: k, f: Float(u - Double(k)))
        }
    }

    /// eine Spalte aus den Blöcken `from..<to` rastern: `half` Zeilen von der Mitte nach außen, Zeile j bei Amplitude
    /// (j + 0,5) / half (volle Höhe = 0 dBFS). Schreibt RGBA (vormultipliziert) je Zeile über `put(j, r, g, b, a)`.
    ///
    /// Farbe je Zeile: die drei Bänder eines Blocks werden nach ihrer Spitze gestapelt – das stärkste Band bildet den
    /// Körper von der Mitte aus, das schwächste liegt außen an den Spitzen (Bass-Körper rot, Hats blau außen);
    /// jedes Band hat zusätzlich einen Grundanteil in allen Zeilen, damit ein mittenlastiger Abschnitt als Ganzes
    /// gelb / grün wird. Deckung und damit Helligkeit kommen nur aus den Blöcken der Spalte selbst, die Farbe aus dem
    /// Fenster `Palette.window` um die Spalte.
    ///
    /// `edges`: Anteil des ersten und letzten Blocks an der Spalte (angeschnittene Randblöcke zählen anteilig).
    /// `between`: Spalte schmaler als ein Block – Höhe, Effektivwert und Bänder linear zwischen den beiden nächsten
    /// Block-Mitten (keine Stufen je Block); sonst das Maximum über `from..<to`. Die oberste Zeile deckt nur den Bruchteil,
    /// den die Spitze erreicht (Alpha anteilig, keine harte Kante).
    @inline(__always)
    /// `open`: je Block 0…255 = Anteil gehaltener Höhen (aus der Höhen-Dauer des Spektrums), nil = alle kurz;
    /// `warm`: je Block 0…255 = Anteil gehaltener Tiefen (`warmth`), nil = alles Anschlag
    public static func column(peak: UnsafeBufferPointer<Float>, blend: UnsafeBufferPointer<UInt8>, open: UnsafeBufferPointer<UInt8>? = nil,
                              warm: UnsafeBufferPointer<UInt8>? = nil, from: Int, to: Int, edges: (first: Float, last: Float) = (1, 1),
                              between: Between? = nil,
                              half: Int, palette p: Palette, put: (Int, UInt8, UInt8, UInt8, UInt8) -> Void) {
        let n = min(peak.count, blend.count / WaveBlend.stride)
        guard n > 0, half > 0 else { return }
        let lo: Int, hi: Int
        if let between {
            lo = max(0, min(n - 1, between.k)); hi = min(n, lo + 2)
        } else {
            lo = max(0, min(n - 1, from)); hi = max(lo + 1, min(n, to))
        }
        let wlo = max(0, lo - p.window), whi = min(n, hi + p.window)
        let slots = whi - wlo + (between == nil ? 0 : 1)
        withUnsafeTemporaryAllocation(of: Sample.self, capacity: slots) { buf in
            var m = 0
            for k in wlo..<whi {
                let w: Float = between != nil || k < lo || k >= hi ? 0 : k == lo ? edges.first : k == hi - 1 ? edges.last : 1
                buf.initializeElement(at: m, to: Sample.read(k, peak: peak, blend: blend, open: open, warm: warm, w: hi - lo == 1 && w > 0 ? 1 : w, p))
                m += 1
            }
            if let between {
                let a = buf[lo - wlo], b = hi - lo > 1 ? buf[lo + 1 - wlo] : a
                buf.initializeElement(at: m, to: Sample.lerp(a, b, between.f, p))
                m += 1
            }
            defer { _ = buf.deinitialize() }
            raster(buf, half: half, palette: p, put: put)
        }
    }

    /// Zeilen einer Spalte aus den gelesenen Blöcken: Deckung nach Anteil der Blöcke an der Spalte gewichtet (ein
    /// angeschnittener Randblock zählt nur anteilig – keine helleren / dunkleren Einzelspalten)
    @inline(__always)
    static func raster(_ s: UnsafeMutableBufferPointer<Sample>, half: Int, palette p: Palette,
                       put: (Int, UInt8, UInt8, UInt8, UInt8) -> Void) {
        var top: Float = 0, count: Float = 0, wmax: Float = 0
        for x in s where x.own { top = max(top, x.pk); count += x.w; wmax = max(wmax, x.w) }
        guard count > 0 else { return }
        let fh = Float(half)
        let rows = min(half, Int((top * fh).rounded(.up)))
        guard rows > 0 else { return }
        let inv = 1 / fh, base = p.base, rest = 1 - p.base
        for j in 0..<rows {
            let jf = Float(j), y = (jf + 0.5) * inv
            var c: Float = 0, area: Float = 0
            var wc: Float = 0, er: Float = 0, eg: Float = 0, eb: Float = 0, eo: Float = 0, ew: Float = 0
            for i in 0..<s.count {
                let x = s[i], pk = x.pk
                // eigener Block: Anteil der Zeile unter der Spitze; Deckung in der Mitte dieses Anteils, Alpha = größter Anteil
                var yy = y
                if x.own {
                    let a = min(1, pk * fh - jf)
                    guard a > 0.004 else { continue }
                    if a < 1 { yy = (jf + a * 0.5) * inv }
                    area = max(area, a * x.w / wmax)
                } else {
                    guard y < pk else { continue }
                }
                let cov = coverage(yy, pk, x.r)
                if x.own { c += cov * x.w }
                let sum = x.pl + x.pm + x.ph
                guard sum > 0 else { continue }
                // Stapel: größtes Band unten (Mitte), kleinstes oben (Spitze); Abschnitte auf die Blockspitze skaliert
                let pl = x.pl, pm = x.pm, ph = x.ph
                let scale = pk / sum, f = p.fade * pk
                var gl: Float = 0, gm: Float = 0, gh: Float = 0
                if pl >= pm, pl >= ph {
                    if pm >= ph {   // L M H
                        gl = inside(yy, 0, pl * scale, f); gm = inside(yy, pl * scale, (pl + pm) * scale, f)
                        gh = inside(yy, (pl + pm) * scale, pk, f)
                    } else {        // L H M
                        gl = inside(yy, 0, pl * scale, f); gh = inside(yy, pl * scale, (pl + ph) * scale, f)
                        gm = inside(yy, (pl + ph) * scale, pk, f)
                    }
                } else if pm >= pl, pm >= ph {
                    if pl >= ph {   // M L H
                        gm = inside(yy, 0, pm * scale, f); gl = inside(yy, pm * scale, (pm + pl) * scale, f)
                        gh = inside(yy, (pm + pl) * scale, pk, f)
                    } else {        // M H L
                        gm = inside(yy, 0, pm * scale, f); gh = inside(yy, pm * scale, (pm + ph) * scale, f)
                        gl = inside(yy, (pm + ph) * scale, pk, f)
                    }
                } else {
                    if pl >= pm {   // H L M
                        gh = inside(yy, 0, ph * scale, f); gl = inside(yy, ph * scale, (ph + pl) * scale, f)
                        gm = inside(yy, (ph + pl) * scale, pk, f)
                    } else {        // H M L
                        gh = inside(yy, 0, ph * scale, f); gm = inside(yy, ph * scale, (ph + pm) * scale, f)
                        gl = inside(yy, (ph + pm) * scale, pk, f)
                    }
                }
                // Anteile: Stapel-Abschnitt (klare Trennung) + Grundanteil aus der Energie-Mischung (Tönung); leise
                // Blöcke (Summe nahe dem Grundpegel) dunkler
                let gsum = gl + gm + gh, msum = x.gl + x.gm + x.gh
                let q = msum / (msum + floor), mi = base / (msum + 1e-9), si = gsum > 0 ? rest / gsum : 0
                let lr = cov * q * (x.gl * mi + gl * si)
                er += lr
                ew += lr * x.warm
                eg += cov * q * (x.gm * mi + gm * si)
                let hb = cov * q * (x.gh * mi + gh * si)
                eb += hb
                eo += hb * x.open
                wc += cov
            }
            guard c > 0, wc > 0 else { continue }
            let L = brightness(c / count) * area
            let rgb = paint((er / wc, eg / wc, eb / wc), p, open: eb > 0 ? eo / eb : 0, warm: er > 0 ? ew / er : 0)
            put(j, UInt8(rgb.r * L * 255), UInt8(rgb.g * L * 255), UInt8(rgb.b * L * 255), UInt8(L * 255))
        }
    }
}
