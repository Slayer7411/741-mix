import MixDSP

/// Testhilfe: ein Plugin als einziger Slot von FX-Unit × Deck (nil = Rack leer)
func setSlotPlugin(_ e: OpaquePointer, _ u: Int32, _ d: Int32, _ p: OpaquePointer?) {
    var kinds: [Int32] = [Int32(p == nil ? MDFX_KIND_NONE.rawValue : MDFX_KIND_PLUGIN.rawValue)]
    var list: [OpaquePointer?] = [p]
    kinds.withUnsafeMutableBufferPointer { k in list.withUnsafeMutableBufferPointer { mdsp_set_fx_rack(e, u, d, k.baseAddress, $0.baseAddress, 1) } }
}

/// Testhilfe: eingebaute Effekte als Slots einer Unit auf allen Decks (Reihenfolge = Signalfluss)
func setRack(_ e: OpaquePointer, _ u: Int32, _ kinds: [MDFXKind]) {
    var k: [Int32] = kinds.map { Int32($0.rawValue) }
    var none = [OpaquePointer?](repeating: nil, count: kinds.count)
    for d in 0..<Int32(MDSP_DECKS) {
        k.withUnsafeMutableBufferPointer { kb in none.withUnsafeMutableBufferPointer { mdsp_set_fx_rack(e, u, d, kb.baseAddress, $0.baseAddress, Int32(kinds.count)) } }
    }
}

/// frühere feste Reihenfolge der eingebauten Effekte (ohne Filter, der Kern hat 6 Slots)
let beatRack: [MDFXKind] = [MDFX_KIND_ROLL, MDFX_KIND_GATER, MDFX_KIND_FLANGER, MDFX_KIND_PHASER, MDFX_KIND_DELAY, MDFX_KIND_REVERB]
let groupRack: [MDFXKind] = [MDFX_KIND_FILTER, MDFX_KIND_DELAY, MDFX_KIND_REVERB]
