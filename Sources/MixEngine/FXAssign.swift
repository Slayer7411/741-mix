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
    /// Parameter-ID im Plugin (nil = eigener Effekt) und Platz des Plugins in der Kette
    public var pluginParam: UInt32?
    public var pluginSlot = 0
    /// Bereich normalisiert (VST3): Anzeige-Text kommt vom Plugin
    public var normalized = false

    public init(id: String, name: String, short: String, group: String = "", unit: String = "", min: Double = 0, max: Double = 1,
                steps: Int = 0, valueNames: [String] = [], defaultValue: Double = 0, bipolar: Bool = false) {
        self.id = id; self.name = name; self.short = short; self.group = group; self.unit = unit
        self.min = min; self.max = max; self.steps = steps; self.valueNames = valueNames
        self.defaultValue = defaultValue; self.bipolar = bipolar
    }

    /// Parameter eines Plugins (AU: Bereich in Einheiten, VST3: normalisiert)
    public init(plugin p: PluginInstance.Parameter, normalized: Bool = false, slot: Int = 0) {
        self.init(id: Self.pluginKey(p.id, slot: slot), name: p.name, short: Self.shortName(p.name), group: p.group, unit: p.units,
                  min: Double(p.min), max: Double(p.max), steps: p.steps, valueNames: p.valueNames)
        curve = p.curve
        pluginParam = p.id
        pluginSlot = slot
        self.normalized = normalized
        bipolar = self.min < 0 && abs(self.min + self.max) < 1e-6 * Swift.max(1, abs(self.min))
        defaultValue = position(Double(p.defaultValue))
    }

    /// Schlüssel eines Plugin-Parameters: Platz 0 "p<id>" (wie mit einem Plugin je Unit), sonst "s<Platz>.p<id>"
    public static func pluginKey(_ id: UInt32, slot: Int = 0) -> String { pluginKey("p\(id)", slot: slot) }
    public static func pluginKey(_ base: String, slot: Int) -> String { slot == 0 ? base : "s\(slot).\(base)" }

    /// Platz und Grundschlüssel eines Plugin-Schlüssels ("s2.p7" → (2, "p7"), "p7"/"@1" → (0, …)); nil = eigener Parameter
    public static func pluginSlot(of key: String) -> (Int, String)? {
        var k = 0, base = Substring(key)
        if key.hasPrefix("s"), let dot = key.firstIndex(of: "."), let n = Int(key[key.index(after: key.startIndex)..<dot]) {
            k = n; base = key[key.index(after: dot)...]
        }
        guard base.count > 1, base.first == "p" || base.first == "@", base.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return (k, String(base))
    }

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
        case "Hz": return abs(v) >= 1000 ? String(format: "%.2f kHz", v / 1000) : abs(v) < 10 ? String(format: "%.2f Hz", v) : String(format: "%.0f Hz", v)
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

// MARK: - Eigene Effekte und Slots

/// Parameter, Standardbelegung und Werte der eingebauten Effekte und der Slots einer Unit.
/// Schlüssel: "dw" = D/W der Unit; je Slot k Vorsatz "" (Slot 1) bzw. "s<k>." und dann "on", "mix", ein Parameter des
/// eingebauten Effekts ("cutoff", "rate" …) oder "p<id>" (Plugin-Parameter, wie FXParam.pluginKey)
public enum FXCatalog {
    /// trennt die Effekte in der Kennung eines Racks
    public static let rackSeparator = " > "
    public typealias Effect = FXUnitState.Effect

    /// Beat-Teiler als Text ("1/4", "3/2", "8")
    static func beatNames(_ list: [Double]) -> [String] {
        list.map { b in
            if b >= 1, b == b.rounded() { return String(Int(b)) }
            for d in [2, 4, 8, 16, 32] where (b * Double(d)) == (b * Double(d)).rounded() { return "\(Int(b * Double(d)))/\(d)" }
            return String(format: "%.2f", b)
        }
    }
    static let beatNames = beatNames(MixEngine.delayBeats)

    static let dw = FXParam(id: "dw", name: "Dry/Wet", short: "D/W", unit: "%", max: 100, defaultValue: 1)

    static func pct(_ id: String, _ name: String, _ short: String, group: String = "", def: Double = 0.5, bipolar: Bool = false) -> FXParam {
        FXParam(id: id, name: name, short: short, group: group, unit: "%", min: bipolar ? -100 : 0, max: 100, defaultValue: def, bipolar: bipolar)
    }

    static func beats(_ id: String, _ name: String, _ short: String, group: String = "", def: Double, list: [Double] = MixEngine.delayBeats) -> FXParam {
        let names = beatNames(list)
        return FXParam(id: id, name: name, short: short, group: group, steps: names.count - 1, valueNames: names, defaultValue: def)
    }

    static func toggle(_ id: String, _ name: String, _ short: String, group: String = "", def: Double = 0, names: [String] = []) -> FXParam {
        FXParam(id: id, name: name, short: short, group: group, steps: 1, valueNames: names, defaultValue: def)
    }

    static func hz(_ id: String, _ name: String) -> FXParam {
        var p = FXParam(id: id, name: name, short: "HZ", unit: "Hz", min: 0.02, max: 4, defaultValue: 0.5)
        p.curve = .logarithmic
        return p
    }

    /// Parameter der Beat-FX (ohne D/W, an/aus)
    static func beatParams(_ e: Effect) -> [FXParam] {
        switch e {
        case .gater:
            return [beats("rate", "Gater-Rate", "RATE", def: 2.0 / 3, list: MixEngine.gaterBeats), pct("shape", "Form", "SHAPE", def: 0),
                    pct("width", "Offen", "WIDTH"), toggle("mute", "Stumm", "MUTE"), toggle("trip", "Triole", "TRIP")]
        case .roll:
            return [beats("len", "Roll-Länge", "LEN", def: 0.6, list: MixEngine.rollBeats), pct("filter", "Filter", "FILTER", bipolar: true),
                    pct("decay", "Abklingen", "DECAY", def: 0), toggle("rev", "Rückwärts", "REV")]
        case .flanger, .phaser:
            let def = e == .flanger ? 0.5 : 2.0 / 6
            var list = [beats("rate", "LFO-Rate (Beats)", "RATE", def: def, list: MixEngine.lfoBeats), pct("depth", "Tiefe", "DEPTH", def: 0.7),
                        pct("feedback", "Feedback", "FEEDB", def: e == .flanger ? 0.5 : 0.4), hz("hz", "LFO-Rate (frei)"),
                        toggle("sync", "LFO im Beat", "SYNC", def: 1), toggle("freeze", "LFO-Freeze", "FRZ")]
            if e == .flanger { list.append(FXParam(id: "spread", name: "Stereo-Phase", short: "PHASE", unit: "°", max: 180, defaultValue: 0.5)) }
            else { list.append(toggle("stages", "Stufen", "STAGE", names: ["4", "8"])) }
            return list
        default:
            return []
        }
    }

    public static let beatFX: [Effect] = [.gater, .roll, .flanger, .phaser]

    /// Parameter eines eingebauten Effekts ohne Slot-Vorsatz: an/aus, Anteil, dann seine eigenen
    public static func builtinParams(_ e: Effect) -> [FXParam] {
        let head = [toggle("on", "Effekt an/aus", "ON"), pct("mix", "Anteil (D/W des Slots)", "MIX", def: 1)]
        switch e {
        case .filter:
            return head + [pct("cutoff", "Cutoff", "CUTOFF", bipolar: true), pct("res", "Resonanz", "RES", def: 0.45)]
        case .delay:
            return head + [pct("filter", "Filter", "FILTER", bipolar: true), pct("feedback", "Feedback", "FEEDB", def: 0.45),
                           beats("rate", "Delay-Zeit", "RATE", def: 0.6)]
        case .reverb:
            return head + [pct("size", "Größe", "SIZE", def: 0.6), pct("hp", "Hochpass", "HP", def: 0), pct("lp", "Tiefpass", "LP", def: 1),
                           toggle("freeze", "Freeze", "FRZ"), toggle("send", "D/W der Unit = Send", "SEND", def: 1)]
        case .plugin:
            return head
        default:
            return head + beatParams(e)
        }
    }

    /// Standardwert eines Parameters (eingebaut); Filter-Resonanz und Delay-Feedback ohne eigenen Wert folgen den Einstellungen
    static func defaultValue(_ e: Effect, _ id: String, prefs: EnginePrefs?) -> Double? {
        if let prefs {
            if e == .filter, id == "res" { return max(0, min(1, (prefs.fxFilterResonance - 0.2) / 1.3)) }
            if e == .delay, id == "feedback" { return prefs.delayFeedback }
        }
        return builtinParams(e).first { $0.id == id }?.defaultValue
    }

    /// Stellung eines Parameters im Slot (eingebaut), fehlt = Standard
    public static func param(_ s: FXSlot, _ id: String, prefs: EnginePrefs? = nil) -> Double {
        if let v = s.params[id] { return v }
        guard let e = s.effect else { return 0 }
        return defaultValue(e, id, prefs: prefs) ?? 0
    }

    /// Hauptparameter eines Slots (Schnellregler in der Gruppen-Belegung): Filter = Cutoff, Roll = Länge, sonst Anteil
    public static func main(_ s: FXSlot) -> String {
        switch s.effect {
        case .filter?: "cutoff"
        case .roll?: "len"
        default: "mix"
        }
    }

    /// Vorsatz der Schlüssel eines Slots: Slot 1 ohne (wie früher Single und das erste Plugin), sonst "s<k>."
    public static func prefix(_ k: Int) -> String { k == 0 ? "" : "s\(k)." }

    /// Slot und Grundschlüssel ("s2.rate" → (2, "rate"), "cutoff" → (0, "cutoff")); nil = D/W der Unit oder leer
    public static func split(_ key: String) -> (Int, String)? {
        if key.isEmpty || key == "dw" { return nil }
        if key.hasPrefix("s"), let dot = key.firstIndex(of: "."), let n = Int(key[key.index(after: key.startIndex)..<dot]) {
            return (n, String(key[key.index(after: dot)...]))
        }
        return (0, key)
    }

    /// Name eines Slots für Menüs ("1 DELAY", "2 AUMatrixReverb")
    public static func slotTitle(_ k: Int, _ name: String) -> String { "\(k + 1) " + name }

    /// alle zuweisbaren Parameter der Unit: D/W, je Slot an/aus, Anteil und seine Parameter (Plugins: `plugin[k]`).
    /// Mehrere Slots: Gruppe je Slot ("1 FILTER"); Plugin-Gruppen dahinter ("2 AUDelay · Mix")
    public static func params(_ fx: FXUnitState, plugin: [Int: (name: String, params: [FXParam])] = [:]) -> [FXParam] {
        var list = [dw]
        let named = fx.slots.count > 1
        for (k, s) in fx.slots.enumerated() {
            let title = slotTitle(k, plugin[k]?.name ?? s.effect?.name ?? s.id)
            let own = builtinParams(s.effect ?? .plugin).map { p -> FXParam in
                var q = p
                q.id = prefix(k) + p.id
                if named { q.group = title }
                return q
            }
            list += own
            if let pl = plugin[k] {
                list += pl.params.map { p in
                    var q = p
                    if named { q.group = title + (p.group.isEmpty ? "" : " · " + p.group) }
                    return q
                }
            }
        }
        return list
    }

    /// Gruppen-Belegung: zwei oder mehr Slots, die ersten beiden eingebaut → Regler i = Hauptparameter von Slot i,
    /// Taste i = an/aus von Slot i (wie der frühere Gruppenmodus). Sonst die drei Parameter von Slot 1
    public static func groupLayout(_ fx: FXUnitState) -> Bool {
        fx.slots.count >= 2 && fx.slots[0].effect != nil && fx.slots[1].effect != nil
    }

    /// Standardbelegung: D/W = D/W der Unit; Gruppen-Belegung (siehe groupLayout) oder Slot 1: eingebaut wie früher Single
    /// (REVERB: Taste 2 = Freeze; GATER: Taste 2 = Stumm, 3 = Triole; ROLL: Taste 2 = rückwärts; FLANGER/PHASER: Regler 1 = Rate
    /// (frei: Hz), Taste 2 = LFO-Freeze, 3 = Sync bzw. Stufen), Plugin: die ersten drei Parameter. Taste 1 = an/aus von Slot 1,
    /// freie Tasten 2/3 = an/aus von Slot 2/3
    public static func defaultTarget(_ c: FXControl, fx: FXUnitState, params: [FXParam]) -> String? {
        if c == .dryWet { return "dw" }
        let slots = fx.slots
        guard !slots.isEmpty else { return nil }
        let i = c.isButton ? c.slot - 4 : c.slot - 1
        if groupLayout(fx) {
            guard i < slots.count else { return nil }
            return prefix(i) + (c.isButton ? "on" : main(slots[i]))
        }
        let s0 = slots[0]
        let knobs: [String?], buttons: [String?]
        let free = { (e: Effect) in param(s0, "sync") < 0.5 && s0.effect == e }
        switch s0.effect {
        case .filter?: knobs = ["cutoff", "res", nil]; buttons = [nil, nil]
        case .delay?: knobs = ["filter", "feedback", "rate"]; buttons = [nil, nil]
        case .reverb?: knobs = ["size", "hp", "lp"]; buttons = ["freeze", nil]
        case .gater?: knobs = ["rate", "shape", "width"]; buttons = ["mute", "trip"]
        case .roll?: knobs = ["len", "filter", "decay"]; buttons = ["rev", nil]
        case .flanger?: knobs = [free(.flanger) ? "hz" : "rate", "depth", "feedback"]; buttons = ["freeze", "sync"]
        case .phaser?: knobs = [free(.phaser) ? "hz" : "rate", "depth", "feedback"]; buttons = ["freeze", "stages"]
        default:
            let plug = Array(params.lazy.filter { $0.pluginParam != nil && $0.pluginSlot == 0 }.prefix(3))
            knobs = (0..<3).map { $0 < plug.count ? plug[$0].id : nil }
            buttons = [nil, nil]
        }
        if !c.isButton { return knobs[i] }
        if i == 0 { return "on" }
        if let b = buttons[i - 1] { return b }
        return i < slots.count ? prefix(i) + "on" : nil
    }

    /// Stellung eines eigenen Ziels (D/W, an/aus, Anteil, Parameter eines eingebauten Effekts); Plugin-Parameter = nil
    public static func value(_ id: String, _ fx: FXUnitState, prefs: EnginePrefs? = nil) -> Double? {
        if id == "dw" { return fx.dryWet }
        guard let (k, base) = split(id), fx.slots.indices.contains(k) else { return nil }
        let s = fx.slots[k]
        switch base {
        case "on": return s.on ? 1 : 0
        case "mix": return s.mix
        default:
            guard let e = s.effect, builtinParams(e).contains(where: { $0.id == base }) else { return nil }
            return param(s, base, prefs: prefs)
        }
    }

    /// eigenes Ziel setzen (Stellung 0…1)
    public static func set(_ id: String, _ v: Double, _ fx: inout FXUnitState) {
        if id == "dw" { fx.dryWet = v; return }
        guard let (k, base) = split(id), fx.slots.indices.contains(k) else { return }
        switch base {
        case "on": fx.slots[k].on = v >= 0.5
        case "mix": fx.slots[k].mix = v
        default:
            guard let e = fx.slots[k].effect, builtinParams(e).contains(where: { $0.id == base }) else { return }
            fx.slots[k].params[base] = v
        }
    }
}
