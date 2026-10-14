import Foundation

/// Werte je Band (Tief, Mitte, Hoch)
public struct WaveBands<T: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var low: T, mid: T, high: T
    public init(_ low: T, _ mid: T, _ high: T) { self.low = low; self.mid = mid; self.high = high }
}

/// Farbe 0…1 (sRGB, ohne Alpha)
public struct WaveColor: Codable, Hashable, Sendable {
    public var r: Float, g: Float, b: Float
    public init(_ r: Float, _ g: Float, _ b: Float) { self.r = r; self.g = g; self.b = b }
    public init(_ c: BlendPaint.RGB) { self.init(c.r, c.g, c.b) }
    public var rgb: BlendPaint.RGB { (r, g, b) }
}

/// Analyse-Werte der Band-Hüllkurven (BlendAnalyzer): Trennfrequenzen, Anstieg / Abfall, Gewichte.
/// Standard = die Werte, mit denen der Datei-Dienst die `.mtrk` schreibt
public struct BlendParams: Codable, Hashable, Sendable {
    /// Tiefpass (Hz)
    public var low: Double
    /// Bandpass (Hz), nil = geometrisches Mittel aus Tief und Hoch
    public var mid: Double?
    /// Hochpass (Hz)
    public var high: Double
    public var attackMs: WaveBands<Double>
    public var releaseMs: WaveBands<Double>
    public var weights: WaveBands<Float>

    public init(low: Double = 150, mid: Double? = 670, high: Double = 3000,
                attackMs: WaveBands<Double> = .init(10, 5, 2.5), releaseMs: WaveBands<Double> = .init(100, 35, 25),
                weights: WaveBands<Float> = .init(0.6, 1.0, 1.2)) {
        self.low = low; self.mid = mid; self.high = high
        self.attackMs = attackMs; self.releaseMs = releaseMs; self.weights = weights
    }

    public static let standard = BlendParams()

    /// Bandpass-Frequenz (auto = geometrisches Mittel)
    public var midHz: Double { mid ?? (low * high).squareRoot() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = BlendParams()
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? d.low
        mid = c.contains(.mid) ? try c.decodeIfPresent(Double.self, forKey: .mid) : d.mid
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? d.high
        attackMs = try c.decodeIfPresent(WaveBands<Double>.self, forKey: .attackMs) ?? d.attackMs
        releaseMs = try c.decodeIfPresent(WaveBands<Double>.self, forKey: .releaseMs) ?? d.releaseMs
        weights = try c.decodeIfPresent(WaveBands<Float>.self, forKey: .weights) ?? d.weights
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(low, forKey: .low)
        if let mid { try c.encode(mid, forKey: .mid) } else { try c.encodeNil(forKey: .mid) }
        try c.encode(high, forKey: .high)
        try c.encode(attackMs, forKey: .attackMs); try c.encode(releaseMs, forKey: .releaseMs); try c.encode(weights, forKey: .weights)
    }

    private enum CodingKeys: String, CodingKey { case low, mid, high, attackMs, releaseMs, weights }
}

/// Wellenform-Preset des Stils „3-Band (Mischung)“: Analyse (Trennfrequenzen, Hüllkurven) und Darstellung (Farben,
/// Gewichte, Stapel). Eingebaute Presets sind fest; Ändern legt eine eigene Kopie an (`base` = Herkunft)
public struct WavePreset: Codable, Hashable, Identifiable, Sendable {
    /// Darstellung: Werte von `BlendPaint.Palette` plus Höhen-Betonung
    public struct Look: Codable, Hashable, Sendable {
        public var low: WaveColor, mid: WaveColor, high: WaveColor
        public var highOpen: WaveColor, lowWarm: WaveColor
        public var direct: Bool
        public var gain: WaveBands<Float>
        public var base: Float, fade: Float, stackCurve: Float
        public var warmth: Float, openness: Float, saturation: Float
        public var highShare: Float
        public var window: Int
        /// 0…3, 1 = neutral: Gewicht der Höhen ×2^(x−1)
        public var highBoost: Float

        public init(_ p: BlendPaint.Palette, highBoost: Float = 1) {
            low = WaveColor(p.low); mid = WaveColor(p.mid); high = WaveColor(p.high)
            highOpen = WaveColor(p.highOpen); lowWarm = WaveColor(p.lowWarm)
            direct = p.direct
            gain = .init(p.gain.r, p.gain.g, p.gain.b)
            base = p.base; fade = p.fade; stackCurve = p.stackCurve
            warmth = p.warmth; openness = p.openness; saturation = p.saturation
            highShare = p.highShare; window = p.window
            self.highBoost = highBoost
        }

        public static let standard = Look(.rgb)

        public var palette: BlendPaint.Palette {
            var p = BlendPaint.Palette(low: low.rgb, mid: mid.rgb, high: high.rgb, highOpen: highOpen.rgb, lowWarm: lowWarm.rgb,
                                       direct: direct, highShare: highShare, saturation: saturation, window: window,
                                       gain: (gain.low, gain.mid, gain.high))
            p.gain.b *= Float(pow(2, Double(highBoost) - 1))
            p.base = base; p.fade = fade; p.stackCurve = stackCurve; p.warmth = warmth; p.openness = openness
            return p
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self), d = Look.standard
            func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
            low = try v(.low, d.low); mid = try v(.mid, d.mid); high = try v(.high, d.high)
            highOpen = try v(.highOpen, d.highOpen); lowWarm = try v(.lowWarm, d.lowWarm)
            direct = try v(.direct, d.direct); gain = try v(.gain, d.gain)
            base = try v(.base, d.base); fade = try v(.fade, d.fade); stackCurve = try v(.stackCurve, d.stackCurve)
            warmth = try v(.warmth, d.warmth); openness = try v(.openness, d.openness); saturation = try v(.saturation, d.saturation)
            highShare = try v(.highShare, d.highShare); window = try v(.window, d.window); highBoost = try v(.highBoost, d.highBoost)
        }
    }

    public var id: String
    public var name: String
    public var builtIn: Bool
    /// eigene Kopie eines eingebauten Presets: dessen ID (Zurücksetzen)
    public var base: String?
    public var analysis: BlendParams
    public var look: Look

    public init(id: String = UUID().uuidString, name: String, builtIn: Bool = false, base: String? = nil,
                analysis: BlendParams = .standard, look: Look = .standard) {
        self.id = id; self.name = name; self.builtIn = builtIn; self.base = base; self.analysis = analysis; self.look = look
    }

    public var palette: BlendPaint.Palette { look.palette }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Preset"
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
        base = try c.decodeIfPresent(String.self, forKey: .base)
        analysis = try c.decodeIfPresent(BlendParams.self, forKey: .analysis) ?? .standard
        look = try c.decodeIfPresent(Look.self, forKey: .look) ?? .standard
    }
}

/// eigene Presets (`wave-presets.json`) über den eingebauten: Liste, Auswahl, Anlegen, Kopieren, Umbenennen, Löschen
public struct WavePresetList: Equatable, Sendable {
    public let builtIn: [WavePreset]
    public var custom: [WavePreset]

    public init(builtIn: [WavePreset], custom: [WavePreset] = []) {
        self.builtIn = builtIn
        let fixed = Set(builtIn.map(\.id))
        // eingebaute IDs und doppelte nicht aus der Datei übernehmen
        var seen = Set<String>()
        self.custom = custom.filter { !fixed.contains($0.id) && seen.insert($0.id).inserted }.map { var p = $0; p.builtIn = false; return p }
    }

    public var all: [WavePreset] { builtIn + custom }

    public func preset(_ id: String) -> WavePreset? { all.first { $0.id == id } }

    /// gewähltes Preset, unbekannt -> erstes eingebautes
    public func resolved(_ id: String) -> WavePreset { preset(id) ?? builtIn[0] }

    /// freier Name: „Name“, sonst „Name 2“, „Name 3“ …
    public func uniqueName(_ name: String) -> String {
        let names = Set(all.map(\.name))
        guard names.contains(name) else { return name }
        var n = 2
        while names.contains("\(name) \(n)") { n += 1 }
        return "\(name) \(n)"
    }

    /// Kopie von `id` (Name „<Name> <suffix>“), hinten angehängt; liefert die neue ID
    @discardableResult
    public mutating func copy(_ id: String, suffix: String, name: String? = nil) -> String? {
        guard let src = preset(id) else { return nil }
        let p = WavePreset(name: uniqueName(name ?? "\(src.name) \(suffix)"), base: src.builtIn ? src.id : src.base,
                           analysis: src.analysis, look: src.look)
        custom.append(p)
        return p.id
    }

    public mutating func rename(_ id: String, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = custom.firstIndex(where: { $0.id == id }) else { return }
        custom[i].name = n
    }

    /// nur eigene; liefert die ID, die danach gewählt sein soll (Herkunft oder Standard)
    @discardableResult
    public mutating func delete(_ id: String) -> String? {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return nil }
        let p = custom.remove(at: i)
        return p.base.flatMap { b in builtIn.contains { $0.id == b } ? b : nil } ?? builtIn[0].id
    }

    /// eigene Kopie auf die Werte ihres eingebauten Presets zurück (Name bleibt)
    public mutating func reset(_ id: String) {
        guard let i = custom.firstIndex(where: { $0.id == id }), let b = custom[i].base.flatMap({ b in builtIn.first { $0.id == b } }) else { return }
        custom[i].analysis = b.analysis
        custom[i].look = b.look
    }

    /// eigenes Preset ändern (eingebaute bleiben unverändert)
    public mutating func update(_ id: String, _ f: (inout WavePreset) -> Void) {
        guard let i = custom.firstIndex(where: { $0.id == id }) else { return }
        f(&custom[i])
    }

    // MARK: Datei

    private struct File: Codable { var version = 1; var presets: [WavePreset] }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(File(presets: custom))
    }

    public static func decodeCustom(_ data: Data) throws -> [WavePreset] {
        try JSONDecoder().decode(File.self, from: data).presets
    }
}
