import MixDSP

/// Dünne Sicht auf ein Deck im C++-Kern (Play/Reverse/Flux); der Zustand liegt atomar im Kern.
public final class DeckPlayer: @unchecked Sendable {
    let e: OpaquePointer
    let d: Int32
    init(_ e: OpaquePointer, _ d: Int) { self.e = e; self.d = Int32(d) }

    public var playing: Bool {
        get { mdsp_playing(e, d) }
        set { mdsp_set_param(e, d, MD_PLAYING, newValue ? 1 : 0) }
    }
    public var reverse: Bool = false { didSet { mdsp_set_param(e, d, MD_REVERSE, reverse ? 1 : 0) } }
    public var flux: Bool = false { didSet { mdsp_set_param(e, d, MD_FLUX, flux ? 1 : 0) } }
}
