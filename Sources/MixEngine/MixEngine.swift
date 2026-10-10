import AudioToolbox
import CoreAudio
import Foundation
import MixDSP

/// Die Audio-Engine: Swift-Fassade um den C++-Echtzeitkern (MixDSP) und einen einzigen CoreAudio-Ausgang.
/// Signalweg je Deck (alles im Kern, ein Render-Callback):
/// Track → Tempo (Varispeed oder Keylock/Signalsmith) → Gain → EQ → Filter → FX 1 → FX 2 → Fader × Crossfader → Kanalpaar
public final class MixEngine: @unchecked Sendable {
    public static let deckCount = Int(MDSP_DECKS)
    public static let fxUnitCount = Int(MDSP_FX_UNITS)
    /// Delay-Zeiten in Beats (FXUnitState.delayIndex)
    public static let delayBeats: [Double] = [1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 3.0 / 2, 2]

    let core: OpaquePointer
    private let output = CoreAudioOutput()
    private var players: [DeckPlayer] = []
    /// Rate, mit der Tracks dekodiert werden (= Geräterate beim Start; andere Raten gleicht der Kern aus)
    public let sampleRate: Double
    public private(set) var lastError: String?
    public private(set) var routing = Routing()
    public var running: Bool { output.running }
    public var deviceChannels: Int { output.channels }
    /// Puffergröße in Frames (nil = Gerätestandard)
    public var bufferFrames: UInt32?

    /// Wird gerufen, wenn sich die Geräteliste ändert und unser Gerät weg ist (Hauptthread)
    public var onConfigurationChange: (@Sendable () -> Void)?

    public struct Routing: Equatable, Sendable {
        public var device: AudioDeviceID?
        public var firstChannel: [Int] = [0, 0, 0, 0]
        public init(device: AudioDeviceID? = nil, firstChannel: [Int] = [0, 0, 0, 0]) {
            self.device = device
            self.firstChannel = firstChannel
        }
    }

    public init() {
        let dev = Self.defaultOutputDevice() ?? 0
        sampleRate = Self.nominalRate(dev) ?? 44100
        core = mdsp_create(sampleRate)
        players = (0..<Self.deckCount).map { DeckPlayer(core, $0) }
        listenForDeviceChanges()
    }

    deinit {
        output.stop()
        mdsp_destroy(core)
    }

    public func player(_ d: Int) -> DeckPlayer { players[d] }

    // MARK: - Ausgabe

    public func start() { apply(routing) }
    public func stop() { output.stop() }

    /// Gerät und Kanalpaare setzen. Kanalwechsel ohne Neustart; nur ein Gerätewechsel startet die Ausgabe neu.
    public func apply(_ r: Routing) {
        let deviceChanged = r.device != routing.device || !output.running
        routing = r
        for d in 0..<Self.deckCount { mdsp_set_param(core, Int32(d), MD_OUT_CHANNEL, Float(r.firstChannel[d])) }
        guard deviceChanged else { return }
        do {
            try output.start(device: r.device, engine: core, bufferFrames: bufferFrames)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func listenForDeviceChanges() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            let ids = Set(Self.outputDevices().map(\.id))
            // nur reagieren, wenn unser Gerät verschwunden oder wieder da ist
            if let dev = self.routing.device, !ids.contains(dev) || !self.output.running { self.onConfigurationChange?() }
        }
    }

    // MARK: - Laden / Transport

    /// Track-Puffer an ein Deck geben. Den alten Puffer erst freigeben, wenn `bufferReleased(d)` true ist.
    public func attach(_ audio: TrackAudio?, deck d: Int, startAt seconds: Double) {
        players[d].reverse = false
        mdsp_set_track(core, Int32(d), audio?.left, audio?.right, Int64(audio?.frames ?? 0), audio?.sampleRate ?? sampleRate, seconds)
    }

    public func bufferReleased(_ d: Int) -> Bool { mdsp_buffer_released(core, Int32(d)) }
    public func seek(_ d: Int, seconds: Double) { mdsp_seek(core, Int32(d), max(0, seconds)) }
    public func position(_ d: Int) -> Double { mdsp_position(core, Int32(d)) }
    public func fluxPosition(_ d: Int) -> Double { mdsp_flux_position(core, Int32(d)) }

    public func setLoop(_ d: Int, active: Bool, start: Double, end: Double) {
        mdsp_set_loop(core, Int32(d), active, start, end)
    }

    public func loop(_ d: Int) -> (active: Bool, start: Double, end: Double) {
        var s = 0.0, e = 0.0
        let a = mdsp_loop(core, Int32(d), &s, &e)
        return (a, s, e)
    }

    /// Tempo-Faktor und Keylock. `idle` wird nicht gebraucht – der Kern rechnet stehende Decks gar nicht.
    public func setRate(_ d: Int, rate: Double, keylock: Bool, keyShift: Double, idle: Bool = false) {
        mdsp_set_param(core, Int32(d), MD_RATE, Float(rate))
        mdsp_set_param(core, Int32(d), MD_KEYLOCK, keylock ? 1 : 0)
        mdsp_set_param(core, Int32(d), MD_KEYSHIFT, Float(keyShift))
    }

    // MARK: - Mixer

    public func setEQ(_ d: Int, low: Double, mid: Double, high: Double, kill: Bool = true) {
        func g(_ v: Double) -> Float { Float(kill && v <= -25 ? -96 : v) }
        mdsp_set_param(core, Int32(d), MD_EQ_LOW, g(low))
        mdsp_set_param(core, Int32(d), MD_EQ_MID, g(mid))
        mdsp_set_param(core, Int32(d), MD_EQ_HIGH, g(high))
    }

    public func setGain(_ d: Int, db: Double) { mdsp_set_param(core, Int32(d), MD_GAIN_DB, Float(max(-24, min(24, db)))) }

    public func setChannelFilter(_ d: Int, _ v: Double, resonance: Double = 0.6) {
        mdsp_set_param(core, Int32(d), MD_FILTER, Float(v))
        mdsp_set_param(core, Int32(d), MD_FILTER_RES, Float(resonance))
    }

    public func setChannelVolume(_ d: Int, _ v: Double) { mdsp_set_param(core, Int32(d), MD_VOLUME, Float(max(0, min(1, v)))) }
    public func setMasterVolume(_ v: Double) { mdsp_set_master(core, Float(max(0, min(1, v)))) }

    // MARK: - FX

    /// FX-Unit (Gruppenmodus Filter · Delay · Reverb) setzen und Deck zuweisen
    public func applyFX(unit u: Int, deck d: Int, _ fx: FXUnitState, assigned: Bool, bpm: Double,
                        feedback: Double, filterResonance: Double) {
        let un = Int32(u)
        mdsp_set_param(core, Int32(d), u == 0 ? MD_FX1_ASSIGN : MD_FX2_ASSIGN, assigned ? 1 : 0)
        mdsp_set_fx(core, un, MDFX_DRYWET, Float(fx.dryWet))
        mdsp_set_fx(core, un, MDFX_FILTER_ON, fx.slots[0].on ? 1 : 0)
        mdsp_set_fx(core, un, MDFX_FILTER_AMOUNT, Float(fx.slots[0].amount))
        mdsp_set_fx(core, un, MDFX_FILTER_RES, Float(filterResonance))
        mdsp_set_fx(core, un, MDFX_DELAY_ON, fx.slots[1].on ? 1 : 0)
        mdsp_set_fx(core, un, MDFX_DELAY_AMOUNT, Float(fx.slots[1].amount))
        let idx = max(0, min(Self.delayBeats.count - 1, fx.delayIndex))
        mdsp_set_fx(core, un, MDFX_DELAY_SECONDS, Float(min(2, Self.delayBeats[idx] * 60 / (bpm > 0 ? bpm : 125))))
        mdsp_set_fx(core, un, MDFX_DELAY_FEEDBACK, Float(feedback))
        mdsp_set_fx(core, un, MDFX_REVERB_ON, fx.slots[2].on ? 1 : 0)
        mdsp_set_fx(core, un, MDFX_REVERB_AMOUNT, Float(fx.slots[2].amount))
        mdsp_set_fx(core, un, MDFX_REVERB_SIZE, Float(fx.reverbSize))
    }

    public func setReverbSize(unit u: Int, _ size: Double) { mdsp_set_fx(core, Int32(u), MDFX_REVERB_SIZE, Float(size)) }

    // MARK: - Pegel

    public final class Level: @unchecked Sendable {
        let e: OpaquePointer
        let d: Int32
        init(_ e: OpaquePointer, _ d: Int) { self.e = e; self.d = Int32(d) }
        public var rms: Float { var r: Float = 0, p: Float = 0; mdsp_levels(e, d, &r, &p); return r }
        public var peak: Float { var r: Float = 0, p: Float = 0; mdsp_levels(e, d, &r, &p); return p }
    }

    public lazy var levels: [Level] = (0..<Self.deckCount).map { Level(core, $0) }
}
