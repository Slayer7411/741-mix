import Foundation
import MixDSP

// MARK: - Insert-Slots
// Eine FX-Unit (und der Master-Bus) = 0…MixEngine.slotCount Slots in Reihe, je Slot ein Effekt: eingebaut oder Plugin.
// Reihenfolge = Signalfluss. Jeder eingebaute Effekt höchstens einmal je Unit (eine Instanz im Kern).

/// Slot einer FX-Unit oder des Master-Busses
public struct FXSlot: Equatable, Sendable, Codable {
    /// Kennung zur Laufzeit (Plugin-Instanzen folgen dem Slot beim Verschieben), nicht gespeichert
    public var uid = UUID()
    /// eingebauter Effekt ("FILTER", "DELAY", "REVERB", "GATER", "ROLL", "FLANGER", "PHASER") oder Plugin-ID ("aufx:mrev:appl")
    public var id: String
    /// aus = durchgereicht, die Fahne klingt aus
    public var on: Bool
    /// D/W des Slots 0…1
    public var mix: Double
    /// eingebauter Effekt: Stellungen 0…1 je Parameter (fehlt = Standard, siehe FXCatalog)
    public var params: [String: Double]
    /// Plugin-Zustand (AU: ClassInfo, VST3: Komponente + Controller)
    public var state: Data?

    public init(id: String, on: Bool = false, mix: Double = 1, params: [String: Double] = [:], state: Data? = nil) {
        self.id = id; self.on = on; self.mix = mix; self.params = params; self.state = state
    }

    public var effect: FXUnitState.Effect? { FXUnitState.Effect(builtin: id) }
    public var isPlugin: Bool { effect == nil }

    enum CodingKeys: String, CodingKey { case id, on, mix, params, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? true   // Plugin-Kette (bis 2026-10): Platz standardmäßig an
        mix = max(0, min(1, try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1))
        // Freeze/Mute kommen nicht aus der Sitzung zurück
        params = (try c.decodeIfPresent([String: Double].self, forKey: .params) ?? [:]).filter { $0.key != "freeze" && $0.key != "mute" }
        state = try c.decodeIfPresent(Data.self, forKey: .state)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(on, forKey: .on); try c.encode(mix, forKey: .mix)
        if !params.isEmpty { try c.encode(params, forKey: .params) }
        try c.encodeIfPresent(state, forKey: .state)
    }

    /// gleicher Effekt mit denselben Einstellungen (ohne Laufzeit-Kennung)
    public func sameSetup(_ o: FXSlot) -> Bool { id == o.id && on == o.on && mix == o.mix && params == o.params && state == o.state }
}

/// FX-Unit: Insert-Slots, D/W der Unit, Belegung der Schnellregler
public struct FXUnitState: Equatable, Sendable, Codable {
    /// eingebaute Effekte. Rohwerte = alte Sitzungen (singleType/slotTypes); `.plugin` nur dort
    public enum Effect: Int, CaseIterable, Sendable {
        case filter = 0, delay, reverb, plugin, gater, roll, flanger, phaser
        public var name: String { ["FILTER", "DELAY", "REVERB", "PLUGIN", "GATER", "ROLL", "FLANGER", "PHASER"][rawValue] }
        /// Kürzel (Vorlagen, Slot-Zeilen)
        public var short: String { ["FLT", "DLY", "REV", "PLG", "GAT", "ROL", "FLG", "PHS"][rawValue] }
        /// eingebaute Effekte in Menü-Reihenfolge
        public static let builtins: [Effect] = [.filter, .delay, .reverb, .gater, .roll, .flanger, .phaser]
        public init?(builtin name: String) {
            guard let e = Self.builtins.first(where: { $0.name == name }) else { return nil }
            self = e
        }
        /// Effekt im Kern (MDFXKind)
        public var kind: Int32 {
            switch self {
            case .filter: Int32(MDFX_KIND_FILTER.rawValue)
            case .delay: Int32(MDFX_KIND_DELAY.rawValue)
            case .reverb: Int32(MDFX_KIND_REVERB.rawValue)
            case .gater: Int32(MDFX_KIND_GATER.rawValue)
            case .roll: Int32(MDFX_KIND_ROLL.rawValue)
            case .flanger: Int32(MDFX_KIND_FLANGER.rawValue)
            case .phaser: Int32(MDFX_KIND_PHASER.rawValue)
            case .plugin: Int32(MDFX_KIND_PLUGIN.rawValue)
            }
        }
    }

    /// Slots in Reihenfolge (Signalfluss); leer = durchgereicht
    public var slots: [FXSlot] = FXTemplate.group.slots
    /// D/W der Unit: Anteil jedes Slots (wirkt nur, solange ein Bedienelement darauf liegt)
    public var dryWet: Double = 1
    /// Zuweisung der Bedienelemente und die Rack-Kennung, zu der sie gehört
    public var mapping = FXMapping()
    public var mappingKey: String?
    /// Plugin-Parameter, die über die Bedienelemente liefen (Schlüssel → Stellung 0…1); beim Laden der Sitzung gesetzt
    public var pluginValues: [String: Double] = [:]

    public init() {}
    public init(slots: [FXSlot], dryWet: Double = 1) { self.slots = slots; self.dryWet = dryWet }

    public var anyOn: Bool { slots.contains { $0.on } }
    /// Slot eines eingebauten Effekts
    public func slot(of e: Effect) -> Int? { slots.firstIndex { $0.effect == e } }
    /// Kennung des Racks für die gemerkte Belegung: Effekt-Namen bzw. Plugin-IDs in Reihenfolge ("FILTER > DELAY > REVERB",
    /// "DELAY", "aufx:mrev:appl > aufx:dely:appl"); leer = ""
    public var effectKey: String { slots.map(\.id).joined(separator: FXCatalog.rackSeparator) }

    enum CodingKeys: String, CodingKey {
        case inserts, dryWet, mapping, mappingKey, pluginValues
        // bis 2026-10: Gruppe (3 Slots) oder Single (ein Effekt oder Plugin-Kette)
        case slots, slotTypes, opts, delayIndex, reverbSize, single, singleType, singleOn, params, chain, pluginID, pluginState
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(slots, forKey: .inserts); try c.encode(dryWet, forKey: .dryWet)
        try c.encode(mapping, forKey: .mapping); try c.encodeIfPresent(mappingKey, forKey: .mappingKey)
        try c.encode(pluginValues, forKey: .pluginValues)
    }

    // tolerant laden: alte Sitzungen (Gruppe/Single/Kette) werden zu Slots
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dryWet = try c.decodeIfPresent(Double.self, forKey: .dryWet) ?? 1
        mapping = try c.decodeIfPresent(FXMapping.self, forKey: .mapping) ?? FXMapping()
        mappingKey = try c.decodeIfPresent(String.self, forKey: .mappingKey)
        pluginValues = try c.decodeIfPresent([String: Double].self, forKey: .pluginValues) ?? [:]
        if let list = try c.decodeIfPresent([FXSlot].self, forKey: .inserts) {
            slots = FXRules.valid(list)
            return
        }
        var old = FXMigration.Old()
        old.single = try c.decodeIfPresent(Bool.self, forKey: .single) ?? false
        old.singleType = try c.decodeIfPresent(Int.self, forKey: .singleType) ?? Effect.delay.rawValue
        old.singleOn = try c.decodeIfPresent(Bool.self, forKey: .singleOn) ?? false
        if let p = try c.decodeIfPresent([Double].self, forKey: .params), p.count == 3 { old.params = p }
        if let s = try c.decodeIfPresent([FXMigration.Old.Slot].self, forKey: .slots), s.count == 3 { old.slots = s }
        if let t = try c.decodeIfPresent([Int].self, forKey: .slotTypes), t.count == 3, Set(t).count == 3,
           t.allSatisfy({ Effect(rawValue: $0).map { $0 != .plugin } ?? false }) { old.slotTypes = t }
        old.opts = try c.decodeIfPresent([String: Double].self, forKey: .opts) ?? [:]
        old.delayIndex = try c.decodeIfPresent(Int.self, forKey: .delayIndex) ?? 3
        old.reverbSize = try c.decodeIfPresent(Double.self, forKey: .reverbSize) ?? 0.6
        if let list = try c.decodeIfPresent([FXSlot].self, forKey: .chain) {
            old.chain = list
        } else if let id = try c.decodeIfPresent(String.self, forKey: .pluginID) {
            old.chain = [FXSlot(id: id, on: true, state: try c.decodeIfPresent(Data.self, forKey: .pluginState))]
        }
        let hadValues = (try? c.decodeIfPresent([String: Double].self, forKey: .pluginValues)) != nil
        FXMigration.apply(old, to: &self, hadPluginValues: hadValues)
    }
}

/// Master-Bus: Insert-Slots nach der Summe der Decks, vor MAIN (nur interner Mixer)
public struct MasterFXState: Equatable, Sendable, Codable {
    public var on = false
    public var dryWet = 1.0
    public var slots: [FXSlot] = []
    public init() {}
    enum CodingKeys: String, CodingKey { case on, dryWet, inserts, chain }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = try c.decodeIfPresent(Bool.self, forKey: .on) ?? false
        dryWet = try c.decodeIfPresent(Double.self, forKey: .dryWet) ?? 1
        // bis 2026-10: Plugin-Kette
        slots = FXRules.valid(try c.decodeIfPresent([FXSlot].self, forKey: .inserts) ?? c.decodeIfPresent([FXSlot].self, forKey: .chain) ?? [])
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(on, forKey: .on); try c.encode(dryWet, forKey: .dryWet); try c.encode(slots, forKey: .inserts)
    }
}

/// Regeln einer Slot-Liste: höchstens MixEngine.slotCount, jeder eingebaute Effekt einmal
public enum FXRules {
    public static func valid(_ list: [FXSlot]) -> [FXSlot] {
        var seen = Set<String>(), out: [FXSlot] = []
        for s in list where out.count < MixEngine.slotCount {
            if s.effect != nil { guard seen.insert(s.id).inserted else { continue } }
            out.append(s)
        }
        return out
    }

    /// Effekt `id` in Slot `k` einsetzen: steht ein eingebauter schon in einem anderen Slot, tauschen beide den Platz;
    /// sonst ersetzt er den Slot (an/aus bleibt, Einstellungen beginnen neu). Liefert die Verschiebung (alt → neu, nil = weg)
    @discardableResult
    public static func replace(_ slots: inout [FXSlot], at k: Int, with id: String, template: FXSlot? = nil) -> [Int?] {
        var perm: [Int?] = Array(slots.indices)
        guard slots.indices.contains(k), slots[k].id != id else { return perm }
        if FXUnitState.Effect(builtin: id) != nil, let j = slots.firstIndex(where: { $0.id == id }) {
            slots.swapAt(k, j)
            perm[k] = j; perm[j] = k
            return perm
        }
        var s = template ?? FXTemplate.slot(id)
        s.on = slots[k].on
        slots[k] = s
        perm[k] = nil
        return perm
    }
}

/// Vorlage: fertige Slot-Liste (Gruppe wie der frühere Gruppenmodus, je eingebauter Effekt ein Slot wie Single)
public struct FXTemplate: Sendable, Equatable {
    public var name: String
    public var slots: [FXSlot]

    /// Gruppe FLT·DLY·REV: Filter, Delay, Reverb, Schnellregler = Stärke je Slot, Tasten = an/aus
    public static let group = FXTemplate(name: "GRUPPE FLT·DLY·REV", slots: [
        FXSlot(id: "FILTER", mix: 1, params: ["cutoff": 0.5]),
        FXSlot(id: "DELAY", mix: 0.5, params: ["rate": 0.6]),
        FXSlot(id: "REVERB", mix: 0.5, params: ["size": 0.6, "hp": 0, "lp": 1, "send": 0]),
    ])

    /// neuer Slot mit Standardwerten (eingebaut: wie früher Single; Plugin: an)
    public static func slot(_ id: String) -> FXSlot {
        switch FXUnitState.Effect(builtin: id) {
        case .filter?: FXSlot(id: id, params: ["res": 0.45])
        case .some: FXSlot(id: id)
        case nil: FXSlot(id: id, on: true)
        }
    }

    /// Vorlagen zum Weiterschalten (Controller: Shift + Mode): Gruppe, dann je eingebauter Effekt ein Slot
    public static let all: [FXTemplate] = [group] + FXUnitState.Effect.builtins.map { FXTemplate(name: $0.name, slots: [slot($0.name)]) }

    /// Vorlage, deren Effekte das Rack gerade hat (gleiche Reihenfolge)
    public static func index(of slots: [FXSlot]) -> Int? { all.firstIndex { $0.slots.map(\.id) == slots.map(\.id) } }
}

// MARK: - Übernahme alter Sitzungen und Belegungen (bis 2026-10: GRP/SNGL/PLUGIN-Kette)

public enum FXMigration {
    struct Old {
        struct Slot: Codable { var on = false; var amount = 0.5 }
        var single = false, singleType = FXUnitState.Effect.delay.rawValue, singleOn = false
        var params = [0.5, 0.45, 0.6]
        var slots = [Slot(), Slot(), Slot()]
        var slotTypes = [0, 1, 2]
        var opts: [String: Double] = [:]
        var delayIndex = 3, reverbSize = 0.6
        var chain: [FXSlot] = []

        var types: [FXUnitState.Effect] { slotTypes.compactMap(FXUnitState.Effect.init) }
        /// frühere Effekt-Kennung (GROUP, GROUP:A/B/C, FILTER …, Plugin-ID bzw. Kette)
        var key: String {
            guard single else { return slotTypes == [0, 1, 2] ? "GROUP" : "GROUP:" + types.map(\.name).joined(separator: "/") }
            let e = FXUnitState.Effect(rawValue: singleType) ?? .delay
            return e == .plugin ? (chain.isEmpty ? "PLUGIN" : chain.map(\.id).joined(separator: FXCatalog.rackSeparator)) : e.name
        }
    }

    /// Einstellungen eines Beat-FX aus den alten `opts` ("GATER.rate" → "rate"), ohne Freeze/Mute
    static func opts(_ o: [String: Double], _ e: FXUnitState.Effect) -> [String: Double] {
        var out: [String: Double] = [:]
        for (k, v) in o where k.hasPrefix(e.name + ".") {
            let id = String(k.dropFirst(e.name.count + 1))
            if id != "freeze" && id != "mute" { out[id] = v }
        }
        return out
    }

    static func apply(_ o: Old, to fx: inout FXUnitState, hadPluginValues: Bool) {
        typealias Effect = FXUnitState.Effect
        var slots: [FXSlot]
        let hidden = o.chain.map { FXSlot(id: $0.id, on: false, mix: 1, state: $0.state) }   // Kette, die nicht aktiv war
        let type = Effect(rawValue: o.singleType) ?? .delay
        if o.single && type == .plugin {
            slots = o.chain.map { FXSlot(id: $0.id, on: o.singleOn && $0.on, mix: 1, state: $0.state) }
        } else if o.single {
            let p = o.params
            var params: [String: Double]
            switch type {
            case .filter: params = ["cutoff": p[0], "res": p[1]]
            case .delay: params = ["filter": p[0], "feedback": p[1], "rate": p[2]]
            case .reverb: params = ["size": p[0], "hp": p[1], "lp": p[2], "send": 1]
            default: params = opts(o.opts, type)
            }
            slots = [FXSlot(id: type.name, on: o.singleOn, mix: 1, params: params)] + hidden
        } else {
            slots = zip(o.types, o.slots).map { e, s -> FXSlot in
                switch e {
                case .filter: return FXSlot(id: e.name, on: s.on, mix: 1, params: ["cutoff": s.amount])
                case .delay: return FXSlot(id: e.name, on: s.on, mix: s.amount, params: ["rate": Double(o.delayIndex) / 5])
                case .reverb: return FXSlot(id: e.name, on: s.on, mix: s.amount, params: ["size": o.reverbSize, "hp": 0, "lp": 1, "send": 0])
                case .roll:
                    var p = opts(o.opts, e); p["filter"] = 0.5   // Gruppe: Roll ohne eigenen Filter
                    return FXSlot(id: e.name, on: s.on, mix: 1, params: p)
                default: return FXSlot(id: e.name, on: s.on, mix: s.amount, params: opts(o.opts, e))
                }
            } + hidden
        }
        fx.slots = FXRules.valid(slots)
        // Plugin-Werte folgen ihrem Slot (versteckte Kette: hinter den eingebauten)
        let offset = o.single && type == .plugin ? 0 : (o.single ? 1 : o.types.count)
        if !hadPluginValues, o.single, type == .plugin, !o.chain.isEmpty {
            // ältere Sitzung: Regler 1–3 = die ersten drei Plugin-Parameter ("@i" = Index, beim Laden aufgelöst)
            for i in 0..<3 { fx.pluginValues["@\(i)"] = o.params[i] }
        }
        if offset > 0 {
            fx.pluginValues = Dictionary(fx.pluginValues.compactMap { k, v -> (String, Double)? in
                guard let (s, base) = FXParam.pluginSlot(of: k), s + offset < fx.slots.count else { return nil }
                return (FXParam.pluginKey(base, slot: s + offset), v)
            }, uniquingKeysWith: { a, _ in a })
        }
        // Belegung der Sitzung: gehörte sie zum geladenen Effekt, gilt sie für das neue Rack
        let oldKey = o.key
        if fx.mappingKey == oldKey {
            fx.mapping = mapping(fx.mapping, key: oldKey, pluginOffset: offset)
            fx.mappingKey = fx.effectKey
        } else {
            fx.mappingKey = nil
        }
    }

    /// alte Kennung → Rack-Kennung ("GROUP" → "FILTER > DELAY > REVERB", "GROUP:A/B/C" → "A > B > C", sonst gleich)
    public static func key(_ old: String) -> String {
        guard let types = groupTypes(old) else { return old }
        return types.map(\.name).joined(separator: FXCatalog.rackSeparator)
    }

    static func groupTypes(_ key: String) -> [FXUnitState.Effect]? {
        if key == "GROUP" { return [.filter, .delay, .reverb] }
        guard key.hasPrefix("GROUP:") else { return nil }
        return key.dropFirst(6).split(separator: "/").compactMap { FXUnitState.Effect(builtin: String($0)) }
    }

    /// Ziele einer alten Belegung: Gruppe "delay" → "s1.mix", "delay.time" → "s1.rate", "reverb.on" → "s2.on" …;
    /// Single und Plugins bleiben (Slot 1 ohne Vorsatz), Plugins einer versteckten Kette rücken um `pluginOffset` Slots
    public static func mapping(_ m: FXMapping, key: String, pluginOffset: Int = 0) -> FXMapping {
        var out = FXMapping()
        let types = groupTypes(key)
        for (c, t) in m.targets {
            out.targets[c] = target(t, types: types, pluginOffset: pluginOffset)
        }
        return out
    }

    static func target(_ t: String, types: [FXUnitState.Effect]?, pluginOffset: Int) -> String {
        if t.isEmpty || t == "dw" { return t }
        if pluginOffset > 0, let (s, base) = FXParam.pluginSlot(of: t) { return FXParam.pluginKey(base, slot: s + pluginOffset) }
        guard let types else { return t }
        let parts = t.split(separator: ".", maxSplits: 1).map(String.init)
        guard let e = types.first(where: { $0.name.lowercased() == parts[0] }), let i = types.firstIndex(of: e) else { return t }
        let sub = parts.count > 1 ? parts[1] : ""
        let base: String = switch (e, sub) {
        case (.filter, ""): "cutoff"
        case (.roll, ""): "len"
        case (_, ""): "mix"
        case (.delay, "time"): "rate"
        default: sub
        }
        return FXCatalog.prefix(i) + base
    }

    /// gemerkte Belegungen (Einstellungen): Gruppen-Kennungen werden Rack-Kennungen. Mehrfach aufrufbar
    public static func mappings(_ m: [String: FXMapping]) -> [String: FXMapping] {
        var out: [String: FXMapping] = [:]
        for (k, v) in m {
            let nk = key(k)
            if nk == k { if out[k] == nil { out[k] = v } } else { out[nk] = mapping(v, key: k) }
        }
        return out
    }
}
