import Foundation
import MixDSP

// Plugin-Ketten im Kern: je FX-Unit × Deck bis zu MDSP_FX_CHAIN Plugins in Reihe, dazu der Master-Bus
// (eine Kette nach der Summe der Decks). Übergabe wie beim einzelnen Plugin: Zeiger-Tausch, Freigabe nach einem Block.

extension MixEngine {
    /// Plätze je Kette
    public static let chainSlots = Int(MDSP_FX_CHAIN)
    /// `unit` der Master-Kette
    public static let masterUnit = Int(MDSP_MASTER_UNIT)

    /// Kette von FX-Unit × Deck (unit = masterUnit: Master-Bus, deck egal) in einem Schritt setzen, Platz 0 zuerst
    public func setChain(unit u: Int, deck d: Int, _ insts: [PluginInstance?]) {
        var ptrs: [OpaquePointer?] = insts.prefix(Self.chainSlots).map { $0?.ptr }
        ptrs.withUnsafeMutableBufferPointer { b in mdsp_set_fx_chain(core, Int32(u), Int32(d), b.baseAddress, Int32(b.count)) }
    }

    /// steht `old` in keinem Platz mehr und rechnet der Audio-Thread es sicher nicht mehr?
    public func chainReleased(unit u: Int, deck d: Int, _ old: PluginInstance) -> Bool {
        mdsp_fx_plugin_released(core, Int32(u), Int32(d), old.ptr)
    }

    /// Platz an/aus (alle Decks der Unit bzw. Master); aus = durchreichen, Fahne klingt aus
    public func setChainSlotOn(unit u: Int, slot k: Int, _ on: Bool) { mdsp_set_fx_chain_on(core, Int32(u), Int32(k), on) }

    /// NaN im Deck oder aus dem Plugin: der Platz wartet auf `reset` (bis dahin durchgereicht)
    public func chainNeedsReset(unit u: Int, deck d: Int, slot k: Int) -> Bool {
        mdsp_fx_chain_needs_reset(core, Int32(u), Int32(d), Int32(k))
    }
    public func chainResetDone(unit u: Int, deck d: Int, slot k: Int) { mdsp_fx_chain_reset_done(core, Int32(u), Int32(d), Int32(k)) }

    /// Master-Bus an/aus und Dry/Wet (0…1)
    public func setMasterFX(on: Bool, dryWet: Double) { mdsp_set_master_fx(core, on, Float(max(0, min(1, dryWet)))) }
    /// Kanalpaar des Master-Busses (erster Kanal), nil = aus
    public func setMasterFXChannel(_ first: Int?) { mdsp_set_master_fx_channel(core, Int32(first ?? -1)) }
    /// Pegel des Master-Paars nach dem Master-Bus, vor MAIN (0 im externen Modus)
    public var masterLevels: (rms: Float, peak: Float) {
        var r: Float = 0, p: Float = 0
        mdsp_master_levels(core, &r, &p)
        return (r, p)
    }
}
