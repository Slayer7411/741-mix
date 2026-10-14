import Foundation
import MixDSP

// Insert-Slots im Kern: je FX-Unit × Deck (und im Master-Bus) bis zu MDSP_FX_SLOTS Slots in Reihe. Belegung (Effekt +
// Plugin je Slot) wird als Ganzes getauscht, herausgenommene Plugins sind frei nach einem Block ohne sie.

extension MixEngine {
    /// Slots je Unit und Master-Bus
    public static let slotCount = Int(MDSP_FX_SLOTS)
    /// `unit` des Master-Busses
    public static let masterUnit = Int(MDSP_MASTER_UNIT)

    /// Slots von FX-Unit × Deck (unit = masterUnit: Master-Bus, deck egal) in einem Schritt setzen: Effekt je Slot
    /// (FXUnitState.Effect.kind), Plugin-Instanz für Plugin-Slots (nil = noch nicht geladen, durchgereicht)
    public func setRack(unit u: Int, deck d: Int, kinds: [Int32], plugins: [PluginInstance?]) {
        let n = min(kinds.count, Self.slotCount)
        var k = Array(kinds.prefix(n))
        var p: [OpaquePointer?] = (0..<n).map { $0 < plugins.count ? plugins[$0]?.ptr : nil }
        k.withUnsafeMutableBufferPointer { kb in
            p.withUnsafeMutableBufferPointer { pb in mdsp_set_fx_rack(core, Int32(u), Int32(d), kb.baseAddress, pb.baseAddress, Int32(n)) }
        }
    }

    /// steht `old` in keinem Slot mehr und rechnet der Audio-Thread es sicher nicht mehr?
    public func pluginReleased(unit u: Int, deck d: Int, _ old: PluginInstance) -> Bool {
        mdsp_fx_plugin_released(core, Int32(u), Int32(d), old.ptr)
    }

    /// NaN im Deck oder aus dem Plugin: der Slot wartet auf `reset` (bis dahin durchgereicht)
    public func slotNeedsReset(unit u: Int, deck d: Int, slot k: Int) -> Bool {
        mdsp_fx_slot_needs_reset(core, Int32(u), Int32(d), Int32(k))
    }
    public func slotResetDone(unit u: Int, deck d: Int, slot k: Int) { mdsp_fx_slot_reset_done(core, Int32(u), Int32(d), Int32(k)) }

    /// Kanalpaar des Master-Busses (erster Kanal), nil = aus
    public func setMasterFXChannel(_ first: Int?) { mdsp_set_master_fx_channel(core, Int32(first ?? -1)) }
    /// Pegel des Master-Paars nach dem Master-Bus, vor MAIN (0 im externen Modus)
    public var masterLevels: (rms: Float, peak: Float) {
        var r: Float = 0, p: Float = 0
        mdsp_master_levels(core, &r, &p)
        return (r, p)
    }

    /// Slots einer Unit (bzw. des Master-Busses, unit = masterUnit) an den Kern: eingebaute Effekte mit ihren Parametern,
    /// Plugin-Slots an/aus und Anteil. Eingebaute ohne Slot sind aus (klingen aus). `assigned`: Deck an der Unit (nicht Master)
    public func applyFX(unit u: Int, deck d: Int, _ fx: FXUnitState, assigned: Bool, bpm: Double,
                        feedback: Double, filterResonance: Double,
                        reverbLevel: Double, reverbBrightness: Double, reverbPreDelay: Double, reverbFDN: Bool = false) {
        typealias Effect = FXUnitState.Effect
        let un = Int32(u)
        if u >= 0 { mdsp_set_param(core, Int32(d), MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(u)), assigned ? 1 : 0) }
        let beat = 60 / (bpm > 0 ? bpm : 125)
        func set(_ p: MDFXParam, _ v: Double) { mdsp_set_fx(core, un, p, Float(v)) }
        func set(_ p: MDFXParam, _ v: Bool) { mdsp_set_fx(core, un, p, v ? 1 : 0) }
        func pick(_ list: [Double], _ v: Double) -> Double { list[max(0, min(list.count - 1, Int((v * Double(list.count - 1)).rounded())))] }
        set(MDFX_DRYWET, fx.dryWet)
        set(MDFX_REVERB_LEVEL, max(0, reverbLevel)); set(MDFX_REVERB_BRIGHT, max(0, min(1, reverbBrightness)))
        set(MDFX_REVERB_PREDELAY, max(0, min(0.2, reverbPreDelay)))
        set(MDFX_REVERB_TYPE, reverbFDN ? 1 : 0)
        var present = Set<Effect>()
        for (k, s) in fx.slots.enumerated() {
            guard let e = s.effect else {
                mdsp_set_fx_slot(core, un, Int32(k), s.on, Float(s.mix))
                continue
            }
            present.insert(e)
            let o = { (id: String) in FXCatalog.param(s, id) }
            /// eigener Filter (Delay davor, Roll danach): an, solange die Stellung nicht in der Mitte steht
            let filterOn = { (v: Double) in s.on && abs(v - 0.5) > 0.02 }
            switch e {
            case .filter:
                let c = o("cutoff")
                set(MDFX_FILTER_ON, s.on); set(MDFX_FILTER_AMOUNT, s.mix == 1 ? c : 0.5 + (c - 0.5) * s.mix)
                set(MDFX_FILTER_RES, s.params["res"].map { 0.2 + $0 * 1.3 } ?? filterResonance)
            case .delay:
                let f = o("filter")
                set(MDFX_DELAY_FILTER_ON, filterOn(f)); set(MDFX_DELAY_FILTER_AMOUNT, f); set(MDFX_DELAY_FILTER_RES, filterResonance)
                set(MDFX_DELAY_ON, s.on); set(MDFX_DELAY_AMOUNT, s.mix); set(MDFX_DELAY_FEEDBACK, s.params["feedback"] ?? feedback)
                let i = max(0, min(Self.delayBeats.count - 1, Int((o("rate") * Double(Self.delayBeats.count - 1)).rounded())))
                set(MDFX_DELAY_SECONDS, min(2, Self.delayBeats[i] * beat))
            case .reverb:
                // Send (Standard): D/W der Unit regelt, wie viel in den Hall geht, der Track läuft trocken weiter.
                // Sonst regelt es den Hall-Anteil (wie früher in der Gruppe)
                set(MDFX_REVERB_ON, s.on); set(MDFX_REVERB_AMOUNT, s.mix); set(MDFX_REVERB_SIZE, o("size"))
                set(MDFX_REVERB_HP, o("hp")); set(MDFX_REVERB_LP, o("lp")); set(MDFX_REVERB_DWSEND, o("send") >= 0.5)
                set(MDFX_REVERB_FREEZE, o("freeze") >= 0.5)
            case .gater:
                set(MDFX_GATER_ON, s.on); set(MDFX_GATER_AMOUNT, s.mix)
                set(MDFX_GATER_BEATS, pick(Self.gaterBeats, o("rate")) * (o("trip") >= 0.5 ? 2.0 / 3 : 1))
                set(MDFX_GATER_SHAPE, o("shape")); set(MDFX_GATER_WIDTH, 0.05 + 0.9 * o("width")); set(MDFX_GATER_MUTE, o("mute") >= 0.5)
            case .roll:
                set(MDFX_ROLL_ON, s.on); set(MDFX_ROLL_AMOUNT, s.mix); set(MDFX_ROLL_BEATS, pick(Self.rollBeats, o("len")))
                set(MDFX_ROLL_REVERSE, o("rev") >= 0.5); set(MDFX_ROLL_DECAY, o("decay") * 24)   // bis −24 dB je Beat
                let f = o("filter")
                set(MDFX_ROLL_FILTER_ON, filterOn(f)); set(MDFX_ROLL_FILTER_AMOUNT, f); set(MDFX_ROLL_FILTER_RES, filterResonance)
            case .flanger:
                set(MDFX_FLANGER_ON, s.on); set(MDFX_FLANGER_AMOUNT, s.mix)
                set(MDFX_FLANGER_BEATS, o("sync") >= 0.5 ? pick(Self.lfoBeats, o("rate")) : 0); set(MDFX_FLANGER_HZ, 0.02 * pow(200, o("hz")))
                set(MDFX_FLANGER_DEPTH, o("depth")); set(MDFX_FLANGER_FEEDBACK, o("feedback")); set(MDFX_FLANGER_SPREAD, o("spread"))
                set(MDFX_FLANGER_FREEZE, o("freeze") >= 0.5)
            case .phaser:
                set(MDFX_PHASER_ON, s.on); set(MDFX_PHASER_AMOUNT, s.mix)
                set(MDFX_PHASER_BEATS, o("sync") >= 0.5 ? pick(Self.lfoBeats, o("rate")) : 0); set(MDFX_PHASER_HZ, 0.02 * pow(200, o("hz")))
                set(MDFX_PHASER_DEPTH, o("depth")); set(MDFX_PHASER_FEEDBACK, o("feedback")); set(MDFX_PHASER_STAGES, o("stages") >= 0.5 ? 8 : 4)
                set(MDFX_PHASER_FREEZE, o("freeze") >= 0.5)
            case .plugin: break
            }
        }
        // ohne Slot: aus (Eingang zu, die Fahne klingt hinter den Slots aus)
        for e in Effect.builtins where !present.contains(e) {
            switch e {
            case .filter: set(MDFX_FILTER_ON, false)
            case .delay: set(MDFX_DELAY_ON, false); set(MDFX_DELAY_FILTER_ON, false)
            case .reverb: set(MDFX_REVERB_ON, false); set(MDFX_REVERB_FREEZE, false)
            case .gater: set(MDFX_GATER_ON, false)
            case .roll: set(MDFX_ROLL_ON, false); set(MDFX_ROLL_FILTER_ON, false)
            case .flanger: set(MDFX_FLANGER_ON, false)
            case .phaser: set(MDFX_PHASER_ON, false)
            case .plugin: break
            }
        }
    }
}
