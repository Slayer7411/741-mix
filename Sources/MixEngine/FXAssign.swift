import Foundation

// MARK: - FX-Belegung
// Je FX-Unit: D/W, Regler 1–3, Tasten 1–3 → ein Parameter des geladenen Effekts (eigener Effekt oder Plugin).
// Werte an den Bedienelementen sind normalisiert (0…1); Parameter-Schlüssel gelten je Effekt-Kennung.

/// Bedienelement einer FX-Unit (Oberfläche und Controller)
public enum FXControl: String, CaseIterable, Codable, Sendable {
    case dryWet = "dw", knob1 = "k1", knob2 = "k2", knob3 = "k3", button1 = "b1", button2 = "b2", button3 = "b3"

    public static func knob(_ i: Int) -> FXControl { [.knob1, .knob2, .knob3][i] }
    public static func button(_ i: Int) -> FXControl { [.button1, .button2, .button3][i] }
    public var isButton: Bool { self == .button1 || self == .button2 || self == .button3 }
    /// Stelle in `MixState.fxControls`
    public var slot: Int {
        switch self {
        case .dryWet: 0
        case .knob1: 1
        case .knob2: 2
        case .knob3: 3
        case .button1: 4
        case .button2: 5
        case .button3: 6
        }
    }
}

/// Zuweisung eines Effekts: Bedienelement → Parameter-Schlüssel. Fehlt ein Element = Standard, "" = nicht zugewiesen
public struct FXMapping: Codable, Equatable, Sendable {
    public var targets: [String: String] = [:]
    public init() {}

    public subscript(_ c: FXControl) -> String? {
        get { targets[c.rawValue] }
        set { targets[c.rawValue] = newValue }
    }

    public var isEmpty: Bool { targets.isEmpty }

    public init(from decoder: Decoder) throws { targets = try decoder.singleValueContainer().decode([String: String].self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(targets)
    }
}

/// Reglerkurve (AU-Display-Flags): Stellung 0…1 → Anteil am Bereich
public enum ParamCurve: Sendable, Equatable {
    case linear, logarithmic, squareRoot, squared, cubeRoot, cubed

    func fraction(_ pos: Double) -> Double {
        switch self {
        case .linear, .logarithmic: pos
        case .squareRoot: pos * pos
        case .squared: pos.squareRoot()
        case .cubeRoot: pos * pos * pos
        case .cubed: cbrt(pos)
        }
    }

    func position(_ f: Double) -> Double {
        switch self {
        case .linear, .logarithmic: f
        case .squareRoot: f.squareRoot()
        case .squared: f * f
        case .cubeRoot: cbrt(f)
        case .cubed: f * f * f
        }
    }
}

/// zuweisbarer Parameter des geladenen Effekts
public struct FXParam: Equatable, Sendable, Identifiable {
    /// eigener Effekt: Feldname ("cutoff"), Plugin: "p" + Parameter-ID
    public var id: String
    public var name: String
    /// Beschriftung am Regler (versal, kurz)
    public var short: String
    /// Gruppe im Menü (Plugin: Clump bzw. Unit), leer = keine
    public var group = ""
    /// Einheit und Bereich der Anzeige
    public var unit = ""
    public var min = 0.0, max = 1.0
    public var curve = ParamCurve.linear
    /// 0 = stufenlos, 1 = Schalter, n > 1 = n + 1 Stufen
    public var steps = 0
    public var valueNames: [String] = []
    /// Standardstellung (normalisiert)
    public var defaultValue = 0.0
    public var bipolar = false
    /// Parameter-ID im Plugin (nil = eigener Effekt)
    public var pluginParam: UInt32?
    /// Bereich normalisiert (VST3): Anzeige-Text kommt vom Plugin
    public var normalized = false

    public init(id: String, name: String, short: String, group: String = "", unit: String = "", min: Double = 0, max: Double = 1,
                steps: Int = 0, valueNames: [String] = [], defaultValue: Double = 0, bipolar: Bool = false) {
        self.id = id; self.name = name; self.short = short; self.group = group; self.unit = unit
        self.min = min; self.max = max; self.steps = steps; self.valueNames = valueNames
        self.defaultValue = defaultValue; self.bipolar = bipolar
    }

    /// Parameter eines Plugins (AU: Bereich in Einheiten, VST3: normalisiert)
    public init(plugin p: PluginInstance.Parameter, normalized: Bool = false) {
        self.init(id: Self.pluginKey(p.id), name: p.name, short: Self.shortName(p.name), group: p.group, unit: p.units,
                  min: Double(p.min), max: Double(p.max), steps: p.steps, valueNames: p.valueNames)
        curve = p.curve
        pluginParam = p.id
        self.normalized = normalized
        bipolar = self.min < 0 && abs(self.min + self.max) < 1e-6 * Swift.max(1, abs(self.min))
        defaultValue = position(Double(p.defaultValue))
    }

    public static func pluginKey(_ id: UInt32) -> String { "p\(id)" }

    public var isSwitch: Bool { steps >= 1 }

    /// Wert in Einheiten zu einer Stellung
    public func plain(_ pos: Double) -> Double {
        let p = Swift.max(0, Swift.min(1, pos))
        if steps > 0 { return min + (max - min) * (p * Double(steps)).rounded() / Double(steps) }
        if curve == .logarithmic, min > 0, max > min { return min * pow(max / min, p) }
        return min + (max - min) * curve.fraction(p)
    }

    /// Stellung zu einem Wert in Einheiten
    public func position(_ plain: Double) -> Double {
        guard max > min else { return 0 }
        if steps == 0, curve == .logarithmic, min > 0 { return Swift.max(0, Swift.min(1, log(Swift.max(plain, min) / min) / log(max / min))) }
        let f = Swift.max(0, Swift.min(1, (plain - min) / (max - min)))
        return steps > 0 ? (f * Double(steps)).rounded() / Double(steps) : curve.position(f)
    }

    /// Stellung auf die nächste Stufe gerastet
    public func snapped(_ pos: Double) -> Double {
        let p = Swift.max(0, Swift.min(1, pos))
        return steps > 0 ? (p * Double(steps)).rounded() / Double(steps) : p
    }

    /// Anzeige mit Einheit ("−6.0 dB", "1/4", "ON")
    public func text(_ pos: Double) -> String {
        if steps > 0 {
            let i = Int((Swift.max(0, Swift.min(1, pos)) * Double(steps)).rounded())
            if i < valueNames.count { return valueNames[i] }
            if steps == 1 { return i == 1 ? "ON" : "OFF" }
        }
        if normalized { return String(format: "%.2f", plain(pos)) + (unit.isEmpty ? "" : " " + unit) }
        return Self.format(plain(pos), unit)
    }

    static func format(_ v: Double, _ unit: String) -> String {
        let num = abs(v) >= 100 ? String(format: "%.0f", v) : abs(v) >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        switch unit {
        case "%": return String(format: "%.0f %%", v)
        case "Hz": return abs(v) >= 1000 ? String(format: "%.2f kHz", v / 1000) : String(format: "%.0f Hz", v)
        case "dB": return String(format: "%+.1f dB", v)
        case "s": return abs(v) < 1 ? String(format: "%.0f ms", v * 1000) : String(format: "%.2f s", v)
        case "ms": return String(format: "%.0f ms", v)
        case "": return num
        default: return num + " " + unit
        }
    }

    /// Bereich als Text für Menüs ("20 Hz … 20.00 kHz"; normalisiert: nur die Einheit)
    public var rangeText: String {
        if normalized || steps > 0 { return unit }
        return Self.format(min, unit) + " … " + Self.format(max, unit)
    }

    /// Parametername für einen Regler: versal, kurz
    public static func shortName(_ n: String) -> String {
        let up = n.uppercased()
        if up.count <= 7 { return up }
        let first = up.split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).first.map(String.init) ?? up
        return String(first.prefix(7))
    }
}

/// Bedienelement mit aufgelöstem Ziel (für Oberfläche und Controller-LEDs)
public struct FXControlInfo: Equatable, Sendable {
    /// Ziel (nil = nicht zugewiesen)
    public var param: FXParam?
    /// Stellung des Ziels (normalisiert)
    public var value = 0.0
    /// Standardbelegung des Effekts
    public var isDefault = true
    /// Beschriftung (Taste in Standardbelegung auf einem An/Aus-Schalter: "ON")
    public var label = "—"
    public init() {}

    /// Taste leuchtet: Schalter/stufenlos ab der Mitte, Liste ab der zweiten Stufe
    public var active: Bool {
        guard let p = param else { return false }
        return p.steps > 1 ? value > 0.001 : value >= 0.5
    }
}

// MARK: - Eigene Effekte

/// Parameter, Standardbelegung und Felder der eigenen Effekte (Gruppe, Filter, Delay, Reverb)
public enum FXCatalog {
    public static let groupKey = "GROUP"

    /// Delay-Zeiten als Text ("1/4", "3/2")
    static let beatNames = MixEngine.delayBeats.map { b -> String in
        if b >= 1, b == b.rounded() { return String(Int(b)) }
        for d in [2, 4, 8] where (b * Double(d)) == (b * Double(d)).rounded() { return "\(Int(b * Double(d)))/\(d)" }
        return String(format: "%.2f", b)
    }

    static let dw = FXParam(id: "dw", name: "Dry/Wet", short: "D/W", unit: "%", max: 100, defaultValue: 1)
    static let on = FXParam(id: "on", name: "Effekt an/aus", short: "ON", steps: 1)

    static func pct(_ id: String, _ name: String, _ short: String, group: String = "", def: Double = 0.5, bipolar: Bool = false) -> FXParam {
        FXParam(id: id, name: name, short: short, group: group, unit: "%", min: bipolar ? -100 : 0, max: 100, defaultValue: def, bipolar: bipolar)
    }

    static func beats(_ id: String, _ name: String, _ short: String, group: String = "", def: Double) -> FXParam {
        FXParam(id: id, name: name, short: short, group: group, steps: beatNames.count - 1, valueNames: beatNames, defaultValue: def)
    }

    /// eigene Parameter eines Effekts (Plugin: D/W + an/aus, dazu die Parameter des Plugins)
    public static func params(for key: String) -> [FXParam] {
        switch key {
        case groupKey:
            return [dw,
                    pct("filter", "Filter-Stärke", "FILTER", group: "FILTER", bipolar: true),
                    FXParam(id: "filter.on", name: "Filter an/aus", short: "FILTER", group: "FILTER", steps: 1),
                    pct("delay", "Delay-Stärke", "DELAY", group: "DELAY"),
                    FXParam(id: "delay.on", name: "Delay an/aus", short: "DELAY", group: "DELAY", steps: 1),
                    beats("delay.time", "Delay-Zeit", "TIME", group: "DELAY", def: 0.6),
                    pct("reverb", "Reverb-Stärke", "REVERB", group: "REVERB"),
                    FXParam(id: "reverb.on", name: "Reverb an/aus", short: "REVERB", group: "REVERB", steps: 1),
                    pct("reverb.size", "Raumgröße", "ROOM", group: "REVERB", def: 0.6),
                    FXParam(id: "reverb.freeze", name: "Reverb-Freeze", short: "FRZ", group: "REVERB", steps: 1)]
        case "FILTER":
            return [dw, on, pct("cutoff", "Cutoff", "CUTOFF", bipolar: true), pct("res", "Resonanz", "RES", def: 0.45)]
        case "DELAY":
            return [dw, on, pct("filter", "Filter", "FILTER", bipolar: true), pct("feedback", "Feedback", "FEEDB", def: 0.45),
                    beats("rate", "Delay-Zeit", "RATE", def: 0.6)]
        case "REVERB":
            return [dw, on, pct("size", "Größe", "SIZE"), pct("hp", "Hochpass", "HP", def: 0.45), pct("lp", "Tiefpass", "LP", def: 0.6),
                    FXParam(id: "freeze", name: "Freeze", short: "FRZ", steps: 1)]
        default:
            return [dw, on]
        }
    }

    /// Standardbelegung (wie vor der Zuweisung): Gruppe = Stärke + an/aus je Slot, Single = die 3 Parameter, Taste 1 = an/aus,
    /// REVERB: Taste 2 = Freeze.
    /// Plugin: Regler 1–3 = die ersten drei Parameter
    public static func defaultTarget(_ c: FXControl, effect key: String, params: [FXParam]) -> String? {
        if c == .dryWet { return "dw" }
        let knobs: [String?]
        switch key {
        case groupKey:
            return c.isButton ? ["filter.on", "delay.on", "reverb.on"][c.slot - 4] : ["filter", "delay", "reverb"][c.slot - 1]
        case "FILTER": knobs = ["cutoff", "res", nil]
        case "DELAY": knobs = ["filter", "feedback", "rate"]
        case "REVERB": knobs = ["size", "hp", "lp"]
        default:
            let plug = Array(params.lazy.filter { $0.pluginParam != nil }.prefix(3))
            knobs = (0..<3).map { $0 < plug.count ? plug[$0].id : nil }
        }
        if c.isButton { return c == .button1 ? "on" : c == .button2 && key == "REVERB" ? "freeze" : nil }
        return knobs[c.slot - 1]
    }

    /// Stellung eines eigenen Parameters
    public static func value(_ id: String, effect key: String, _ fx: FXUnitState) -> Double? {
        switch (key, id) {
        case (_, "dw"): return fx.dryWet
        case (groupKey, "filter"): return fx.slots[0].amount
        case (groupKey, "filter.on"): return fx.slots[0].on ? 1 : 0
        case (groupKey, "delay"): return fx.slots[1].amount
        case (groupKey, "delay.on"): return fx.slots[1].on ? 1 : 0
        case (groupKey, "delay.time"): return Double(fx.delayIndex) / Double(beatNames.count - 1)
        case (groupKey, "reverb"): return fx.slots[2].amount
        case (groupKey, "reverb.on"): return fx.slots[2].on ? 1 : 0
        case (groupKey, "reverb.size"): return fx.reverbSize
        case (groupKey, "reverb.freeze"), ("REVERB", "freeze"): return fx.reverbFreeze ? 1 : 0
        case (groupKey, _): return nil
        case (_, "on"): return fx.singleOn ? 1 : 0
        case ("FILTER", "cutoff"), ("DELAY", "filter"), ("REVERB", "size"): return fx.params[0]
        case ("FILTER", "res"), ("DELAY", "feedback"), ("REVERB", "hp"): return fx.params[1]
        case ("DELAY", "rate"), ("REVERB", "lp"): return fx.params[2]
        default: return nil
        }
    }

    /// eigenen Parameter setzen (Stellung 0…1)
    public static func set(_ id: String, effect key: String, _ v: Double, _ fx: inout FXUnitState) {
        let on = v >= 0.5
        switch (key, id) {
        case (_, "dw"): fx.dryWet = v
        case (groupKey, "filter"): fx.slots[0].amount = v
        case (groupKey, "filter.on"): fx.slots[0].on = on
        case (groupKey, "delay"): fx.slots[1].amount = v
        case (groupKey, "delay.on"): fx.slots[1].on = on
        case (groupKey, "delay.time"): fx.delayIndex = Int((v * Double(beatNames.count - 1)).rounded())
        case (groupKey, "reverb"): fx.slots[2].amount = v
        case (groupKey, "reverb.on"): fx.slots[2].on = on
        case (groupKey, "reverb.size"): fx.reverbSize = v
        case (groupKey, "reverb.freeze"), ("REVERB", "freeze"): fx.reverbFreeze = on
        case (groupKey, _): break
        case (_, "on"): fx.singleOn = on
        case ("FILTER", "cutoff"), ("DELAY", "filter"), ("REVERB", "size"): fx.params[0] = v
        case ("FILTER", "res"), ("DELAY", "feedback"), ("REVERB", "hp"): fx.params[1] = v
        case ("DELAY", "rate"), ("REVERB", "lp"): fx.params[2] = v
        default: break
        }
    }
}

extension FXUnitState {
    /// Kennung des geladenen Effekts für die Zuweisung: GROUP, FILTER, DELAY, REVERB oder die Plugin-ID
    public var effectKey: String {
        guard single else { return FXCatalog.groupKey }
        let e = Effect(rawValue: singleType) ?? .delay
        return e == .plugin ? (pluginID ?? e.name) : e.name
    }

    public var pluginActive: Bool { single && singleType == Effect.plugin.rawValue }
}
