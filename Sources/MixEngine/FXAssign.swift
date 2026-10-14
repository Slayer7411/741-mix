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

// MARK: - Eigene Effekte

/// Parameter, Standardbelegung und Felder der eigenen Effekte (Gruppe, Filter, Delay, Reverb, Gater, Roll, Flanger, Phaser)
public enum FXCatalog {
    public static let groupKey = "GROUP"
    /// trennt die Plugin-IDs in der Kennung einer Kette
    public static let chainSeparator = " > "
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
    static let on = FXParam(id: "on", name: "Effekt an/aus", short: "ON", steps: 1)

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

    /// Parameter der Beat-FX (ohne D/W, an/aus); Schlüssel in FXUnitState.opts = "NAME.id"
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
    static let ownDefaults: [String: Double] = Dictionary(uniqueKeysWithValues: beatFX.flatMap { e in
        beatParams(e).map { ("\(e.name).\($0.id)", $0.defaultValue) }
    })

    /// Einstellung eines Beat-FX (Stellung 0…1), fehlt = Standard
    public static func opt(_ fx: FXUnitState, _ e: Effect, _ id: String) -> Double {
        fx.opts["\(e.name).\(id)"] ?? ownDefaults["\(e.name).\(id)"] ?? 0
    }

    public static func isGroup(_ key: String) -> Bool { key == groupKey || key.hasPrefix(groupKey + ":") }

    /// Effekte der Gruppen-Slots aus der Kennung ("GROUP" = Filter · Delay · Reverb, "GROUP:FILTER/GATER/REVERB")
    public static func groupTypes(_ key: String) -> [Effect] {
        guard key.hasPrefix(groupKey + ":") else { return FXUnitState.defaultSlotTypes.compactMap(Effect.init) }
        return key.dropFirst(groupKey.count + 1).split(separator: "/").compactMap { n in Effect.allCases.first { $0.name == n } }
    }

    /// Kennung des Parameters im Gruppenmodus ("gater", "gater.rate")
    static func groupID(_ e: Effect) -> String { e.name.lowercased() }

    /// Parameter eines Effekts in der Gruppe: Stärke (Roll: Länge) + an/aus, dazu Teiler/Schalter
    static func groupParams(_ e: Effect) -> [FXParam] {
        let g = e.name, id = groupID(e)
        let onoff = FXParam(id: id + ".on", name: e.name.capitalized + " an/aus", short: e.name, group: g, steps: 1)
        switch e {
        case .filter: return [pct("filter", "Filter-Stärke", "FILTER", group: g, bipolar: true), onoff]
        case .delay: return [pct("delay", "Delay-Stärke", "DELAY", group: g), onoff, beats("delay.time", "Delay-Zeit", "TIME", group: g, def: 0.6)]
        case .reverb:
            return [pct("reverb", "Reverb-Stärke", "REVERB", group: g), onoff, pct("reverb.size", "Raumgröße", "ROOM", group: g, def: 0.6),
                    toggle("reverb.freeze", "Reverb-Freeze", "FRZ", group: g)]
        case .gater, .roll, .flanger, .phaser:
            let sub = beatParams(e).filter { ["rate", "mute", "trip", "rev", "freeze", "sync", "stages"].contains($0.id) }.map { p -> FXParam in
                var q = p; q.id = id + "." + p.id; q.group = g; return q
            }
            var amount = e == .roll ? beatParams(.roll)[0] : pct(id, "", e.name, group: g, def: 0.5)
            amount.id = id; amount.short = e == .roll ? "ROLL" : e.name; amount.group = g
            amount.name = ["GATER": "Gater-Tiefe", "ROLL": "Roll-Länge", "FLANGER": "Flanger-Stärke", "PHASER": "Phaser-Stärke"][e.name] ?? e.name
            return [amount, onoff] + sub
        case .plugin: return []
        }
    }

    /// eigene Parameter eines Effekts (Plugin: D/W + an/aus, dazu die Parameter des Plugins)
    public static func params(for key: String) -> [FXParam] {
        if isGroup(key) { return [dw] + groupTypes(key).flatMap(groupParams) }
        switch key {
        case "FILTER":
            return [dw, on, pct("cutoff", "Cutoff", "CUTOFF", bipolar: true), pct("res", "Resonanz", "RES", def: 0.45)]
        case "DELAY":
            return [dw, on, pct("filter", "Filter", "FILTER", bipolar: true), pct("feedback", "Feedback", "FEEDB", def: 0.45),
                    beats("rate", "Delay-Zeit", "RATE", def: 0.6)]
        case "REVERB":
            return [dw, on, pct("size", "Größe", "SIZE"), pct("hp", "Hochpass", "HP", def: 0.45), pct("lp", "Tiefpass", "LP", def: 0.6),
                    FXParam(id: "freeze", name: "Freeze", short: "FRZ", steps: 1)]
        default:
            if let e = beatFX.first(where: { $0.name == key }) { return [dw, on] + beatParams(e) }
            return [dw, on]
        }
    }

    /// Standardbelegung (wie vor der Zuweisung): Gruppe = Stärke + an/aus je Slot, Single = die 3 Parameter, Taste 1 = an/aus,
    /// REVERB: Taste 2 = Freeze; GATER: Taste 2 = Stumm, 3 = Triole; ROLL: Taste 2 = rückwärts; FLANGER/PHASER: Regler 1 = Rate
    /// (frei: Hz), Taste 2 = LFO-Freeze, 3 = Sync bzw. Stufen.
    /// Plugin: Regler 1–3 = die ersten drei Parameter
    public static func defaultTarget(_ c: FXControl, effect key: String, params: [FXParam], fx: FXUnitState? = nil) -> String? {
        if c == .dryWet { return "dw" }
        if isGroup(key) {
            let types = groupTypes(key)
            let i = c.isButton ? c.slot - 4 : c.slot - 1
            guard i < types.count else { return nil }
            return groupID(types[i]) + (c.isButton ? ".on" : "")
        }
        let knobs: [String?], buttons: [String?]
        let free = { (e: Effect) in fx.map { opt($0, e, "sync") < 0.5 } ?? false }
        switch key {
        case "FILTER": knobs = ["cutoff", "res", nil]; buttons = [nil, nil]
        case "DELAY": knobs = ["filter", "feedback", "rate"]; buttons = [nil, nil]
        case "REVERB": knobs = ["size", "hp", "lp"]; buttons = ["freeze", nil]
        case "GATER": knobs = ["rate", "shape", "width"]; buttons = ["mute", "trip"]
        case "ROLL": knobs = ["len", "filter", "decay"]; buttons = ["rev", nil]
        case "FLANGER": knobs = [free(.flanger) ? "hz" : "rate", "depth", "feedback"]; buttons = ["freeze", "sync"]
        case "PHASER": knobs = [free(.phaser) ? "hz" : "rate", "depth", "feedback"]; buttons = ["freeze", "stages"]
        default:
            let plug = Array(params.lazy.filter { $0.pluginParam != nil }.prefix(3))
            knobs = (0..<3).map { $0 < plug.count ? plug[$0].id : nil }
            buttons = [nil, nil]
        }
        if c.isButton { return c == .button1 ? "on" : buttons[c.slot - 5] }
        return knobs[c.slot - 1]
    }

    /// Gruppe: Parameter-Kennung -> Effekt und Unter-Kennung ("gater.rate" -> (.gater, "rate"), "delay" -> (.delay, ""))
    static func groupTarget(_ id: String) -> (Effect, String)? {
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard let e = Effect.allCases.first(where: { groupID($0) == parts[0] }) else { return nil }
        return (e, parts.count > 1 ? parts[1] : "")
    }

    /// Stellung eines eigenen Parameters
    public static func value(_ id: String, effect key: String, _ fx: FXUnitState) -> Double? {
        if id == "dw" { return fx.dryWet }
        if isGroup(key) {
            guard let (e, sub) = groupTarget(id), let i = fx.slotTypes.firstIndex(of: e.rawValue) else { return nil }
            switch (e, sub) {
            case (_, "on"): return fx.slots[i].on ? 1 : 0
            case (.roll, ""): return opt(fx, .roll, "len")
            case (_, ""): return fx.slots[i].amount
            case (.delay, "time"): return Double(fx.delayIndex) / Double(beatNames.count - 1)
            case (.reverb, "size"): return fx.reverbSize
            case (.reverb, "freeze"): return fx.reverbFreeze ? 1 : 0
            case (.gater, _), (.roll, _), (.flanger, _), (.phaser, _): return opt(fx, e, sub)
            default: return nil
            }
        }
        if id == "on" { return fx.singleOn ? 1 : 0 }
        if let e = beatFX.first(where: { $0.name == key }) { return beatParams(e).contains { $0.id == id } ? opt(fx, e, id) : nil }
        switch (key, id) {
        case ("REVERB", "freeze"): return fx.reverbFreeze ? 1 : 0
        case ("FILTER", "cutoff"), ("DELAY", "filter"), ("REVERB", "size"): return fx.params[0]
        case ("FILTER", "res"), ("DELAY", "feedback"), ("REVERB", "hp"): return fx.params[1]
        case ("DELAY", "rate"), ("REVERB", "lp"): return fx.params[2]
        default: return nil
        }
    }

    /// eigenen Parameter setzen (Stellung 0…1)
    public static func set(_ id: String, effect key: String, _ v: Double, _ fx: inout FXUnitState) {
        let on = v >= 0.5
        if id == "dw" { fx.dryWet = v; return }
        if isGroup(key) {
            guard let (e, sub) = groupTarget(id), let i = fx.slotTypes.firstIndex(of: e.rawValue) else { return }
            switch (e, sub) {
            case (_, "on"): fx.slots[i].on = on
            case (.roll, ""): fx.opts["ROLL.len"] = v
            case (_, ""): fx.slots[i].amount = v
            case (.delay, "time"): fx.delayIndex = Int((v * Double(beatNames.count - 1)).rounded())
            case (.reverb, "size"): fx.reverbSize = v
            case (.reverb, "freeze"): fx.reverbFreeze = on
            case (.gater, _), (.roll, _), (.flanger, _), (.phaser, _): fx.opts["\(e.name).\(sub)"] = v
            default: break
            }
            return
        }
        if id == "on" { fx.singleOn = on; return }
        if let e = beatFX.first(where: { $0.name == key }) {
            if beatParams(e).contains(where: { $0.id == id }) { fx.opts["\(e.name).\(id)"] = v }
            return
        }
        switch (key, id) {
        case ("REVERB", "freeze"): fx.reverbFreeze = on
        case ("FILTER", "cutoff"), ("DELAY", "filter"), ("REVERB", "size"): fx.params[0] = v
        case ("FILTER", "res"), ("DELAY", "feedback"), ("REVERB", "hp"): fx.params[1] = v
        case ("DELAY", "rate"), ("REVERB", "lp"): fx.params[2] = v
        default: break
        }
    }
}

extension FXUnitState {
    /// Kennung des geladenen Effekts für die Zuweisung: GROUP (Standard-Slots) bzw. GROUP:FILTER/GATER/REVERB,
    /// FILTER, DELAY, REVERB, GATER, ROLL, FLANGER, PHASER oder die Plugin-ID
    public var effectKey: String {
        guard single else {
            if slotTypes == Self.defaultSlotTypes { return FXCatalog.groupKey }
            return FXCatalog.groupKey + ":" + slotTypes.compactMap { Effect(rawValue: $0)?.name }.joined(separator: "/")
        }
        let e = Effect(rawValue: singleType) ?? .delay
        return e == .plugin ? (chainKey ?? e.name) : e.name
    }

    /// Kennung der Plugin-Kette: Plugin-IDs in Reihenfolge ("aufx:mrev:appl > aufx:dely:appl"), ein Plugin = seine ID
    public var chainKey: String? { chain.isEmpty ? nil : chain.map(\.id).joined(separator: FXCatalog.chainSeparator) }

    public var pluginActive: Bool { single && singleType == Effect.plugin.rawValue }

    /// Gruppen-Slot auf einen Effekt setzen; ist er schon in einem anderen Slot, tauschen beide (jeder höchstens einmal)
    public mutating func setSlot(_ i: Int, _ e: Effect) {
        guard slotTypes.indices.contains(i), Effect.groupable.contains(e) else { return }
        if let j = slotTypes.firstIndex(of: e.rawValue), j != i {
            slotTypes.swapAt(i, j); slots.swapAt(i, j)
        } else if slotTypes[i] != e.rawValue {
            slotTypes[i] = e.rawValue; slots[i].on = false
        }
    }

    /// Slot des Effekts in der Gruppe
    public func slot(of e: Effect) -> Int? { slotTypes.firstIndex(of: e.rawValue) }
}
