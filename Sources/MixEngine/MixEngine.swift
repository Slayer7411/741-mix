import AudioToolbox
import CoreAudio
import Foundation
import MixDSP

/// Die Audio-Engine: Swift-Fassade um den C++-Echtzeitkern (MixDSP) und einen einzigen CoreAudio-Ausgang.
/// Signalweg je Deck (alles im Kern, ein Render-Callback):
/// Track → Tempo (Varispeed oder Keylock/Time-Stretch) → Gain → EQ → Filter → FX 1 → FX 2 → Fader × Crossfader → Kanalpaar
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
    /// Gerät beim Start auf diese Rate stellen (nil = so lassen)
    public var deviceRate: Double?
    /// aktuelle Rate des Geräts
    public var outputRate: Double { output.deviceRate }

    /// Wird gerufen, wenn sich die Geräteliste ändert (Hauptthread); ob neu verbunden wird, entscheidet die Oberfläche
    /// (unser Gerät weg, gewähltes Interface wieder da, Ausgabe läuft nicht)
    public var onConfigurationChange: (@Sendable () -> Void)?

    public struct Routing: Equatable, Sendable {
        public var device: AudioDeviceID?
        public var firstChannel: [Int] = [0, 0, 0, 0]
        public init(device: AudioDeviceID? = nil, firstChannel: [Int] = [0, 0, 0, 0]) {
            self.device = device
            self.firstChannel = firstChannel
        }
    }

    /// `rate` = gewünschte Rate aus den Einstellungen (Kern rechnet damit), sonst die des Standardgeräts
    public init(rate: Double? = nil) {
        let dev = Self.defaultOutputDevice() ?? 0
        sampleRate = rate ?? Self.nominalRate(dev) ?? 44100
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

    /// Gerät und Kanalpaare setzen. Kanalwechsel ohne Neustart; nur ein Gerätewechsel (oder `restart`) startet die Ausgabe neu.
    public func apply(_ r: Routing, restart: Bool = false) {
        let deviceChanged = restart || r.device != routing.device || !output.running
        routing = r
        for d in 0..<Self.deckCount { mdsp_set_param(core, Int32(d), MD_OUT_CHANNEL, Float(r.firstChannel[d])) }
        guard deviceChanged else { return }
        do {
            try output.start(device: r.device, engine: core, engineRate: sampleRate, bufferFrames: bufferFrames, setDeviceRate: deviceRate)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func listenForDeviceChanges() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.onConfigurationChange?()
        }
    }

    // MARK: - Laden / Transport

    /// Track-Puffer an ein Deck geben. Liefert die Übergabe-Generation: den alten Puffer erst freigeben,
    /// wenn `trackConsumed(d, gen)` true ist (Audio-Thread hat den neuen übernommen).
    @discardableResult
    public func attach(_ audio: TrackAudio?, deck d: Int, startAt seconds: Double) -> UInt32 {
        players[d].reverse = false
        return mdsp_set_track(core, Int32(d), audio?.left, audio?.right, Int64(audio?.frames ?? 0), audio?.sampleRate ?? sampleRate, seconds)
    }

    public func trackConsumed(_ d: Int, _ gen: UInt32) -> Bool { mdsp_track_consumed(core, Int32(d), gen) }
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

    /// FX-Unit (Gruppenmodus Filter · Delay · Reverb) setzen und Deck zuweisen.
    /// reverbLevel linear (1 = 0 dB), reverbBrightness 0…1, reverbPreDelay in Sekunden – gelten in beiden Modi.
    public func applyFX(unit u: Int, deck d: Int, _ fx: FXUnitState, assigned: Bool, bpm: Double,
                        feedback: Double, filterResonance: Double,
                        reverbLevel: Double, reverbBrightness: Double, reverbPreDelay: Double) {
        let un = Int32(u)
        mdsp_set_param(core, Int32(d), MDParam(rawValue: MD_FX1_ASSIGN.rawValue + UInt32(u)), assigned ? 1 : 0)
        let beat = 60 / (bpm > 0 ? bpm : 125)
        func set(_ p: MDFXParam, _ v: Double) { mdsp_set_fx(core, un, p, Float(v)) }
        set(MDFX_DRYWET, fx.dryWet)
        set(MDFX_REVERB_LEVEL, max(0, reverbLevel)); set(MDFX_REVERB_BRIGHT, max(0, min(1, reverbBrightness)))
        set(MDFX_REVERB_PREDELAY, max(0, min(0.2, reverbPreDelay)))
        if fx.single {
            // Single-Modus: ein Effekt, die 3 Regler sind seine Parameter
            let on = fx.singleOn, p = fx.params
            let filterOn = { (v: Double) in on && abs(v - 0.5) > 0.02 }
            switch FXUnitState.Effect(rawValue: fx.singleType) ?? .delay {
            case .filter:
                set(MDFX_FILTER_ON, on ? 1 : 0); set(MDFX_FILTER_AMOUNT, p[0]); set(MDFX_FILTER_RES, 0.2 + p[1] * 1.3)
                set(MDFX_DELAY_ON, 0); set(MDFX_REVERB_ON, 0)
            case .delay:
                set(MDFX_FILTER_ON, filterOn(p[0]) ? 1 : 0); set(MDFX_FILTER_AMOUNT, p[0]); set(MDFX_FILTER_RES, filterResonance)
                set(MDFX_DELAY_ON, on ? 1 : 0); set(MDFX_DELAY_AMOUNT, 1); set(MDFX_DELAY_FEEDBACK, p[1])
                let i = max(0, min(Self.delayBeats.count - 1, Int(p[2] * Double(Self.delayBeats.count))))
                set(MDFX_DELAY_SECONDS, min(2, Self.delayBeats[i] * beat))
                set(MDFX_REVERB_ON, 0)
            case .reverb:
                // SIZE, HP, LP – Filter nur vor dem Hall, Track läuft trocken weiter, D/W = wie viel in den Hall geht
                set(MDFX_FILTER_ON, 0); set(MDFX_DELAY_ON, 0)
                set(MDFX_REVERB_ON, on ? 1 : 0); set(MDFX_REVERB_AMOUNT, 1); set(MDFX_REVERB_SIZE, p[0])
                set(MDFX_REVERB_HP, p[1]); set(MDFX_REVERB_LP, p[2]); set(MDFX_REVERB_DWSEND, 1)
            case .plugin:
                // Regler gehen direkt an die Plugin-Parameter (MixController), hier nur an/aus
                set(MDFX_FILTER_ON, 0); set(MDFX_DELAY_ON, 0); set(MDFX_REVERB_ON, 0)
            }
            set(MDFX_PLUGIN_ON, on && FXUnitState.Effect(rawValue: fx.singleType) == .plugin ? 1 : 0)
            if FXUnitState.Effect(rawValue: fx.singleType) != .reverb { set(MDFX_REVERB_HP, 0); set(MDFX_REVERB_LP, 1); set(MDFX_REVERB_DWSEND, 0) }
            return
        }
        set(MDFX_PLUGIN_ON, 0)
        set(MDFX_FILTER_ON, fx.slots[0].on ? 1 : 0)
        set(MDFX_FILTER_AMOUNT, fx.slots[0].amount)
        set(MDFX_FILTER_RES, filterResonance)
        set(MDFX_DELAY_ON, fx.slots[1].on ? 1 : 0)
        set(MDFX_DELAY_AMOUNT, fx.slots[1].amount)
        let idx = max(0, min(Self.delayBeats.count - 1, fx.delayIndex))
        set(MDFX_DELAY_SECONDS, min(2, Self.delayBeats[idx] * beat))
        set(MDFX_DELAY_FEEDBACK, feedback)
        set(MDFX_REVERB_ON, fx.slots[2].on ? 1 : 0)
        set(MDFX_REVERB_AMOUNT, fx.slots[2].amount)
        set(MDFX_REVERB_SIZE, fx.reverbSize)
        set(MDFX_REVERB_HP, 0); set(MDFX_REVERB_LP, 1); set(MDFX_REVERB_DWSEND, 0)
    }

    public func setReverbSize(unit u: Int, _ size: Double) { mdsp_set_fx(core, Int32(u), MDFX_REVERB_SIZE, Float(size)) }

    // MARK: - Plugins

    /// Plugin-Instanz für FX-Unit × Deck in den Kern geben (nil = keins). Liefert den Kern-Zeiger des vorherigen:
    /// dessen Instanz erst freigeben, wenn `pluginReleased` true ist.
    @discardableResult
    public func setPlugin(unit u: Int, deck d: Int, _ p: PluginInstance?) -> OpaquePointer? {
        mdsp_set_fx_plugin(core, Int32(u), Int32(d), p?.ptr)
    }

    /// rechnet der Audio-Thread das alte Plugin sicher nicht mehr?
    public func pluginReleased(unit u: Int, deck d: Int, _ old: PluginInstance) -> Bool {
        mdsp_fx_plugin_released(core, Int32(u), Int32(d), old.ptr)
    }

    // MARK: - Master-Clock

    public func setClockBPM(_ bpm: Double) { mdsp_clock_set_bpm(core, bpm) }
    public func setClockBeat(_ beat: Double) { mdsp_clock_set_beat(core, beat) }
    public var clockBeat: Double { mdsp_clock_beat(core) }
    /// Beat am Anfang des letzten Blocks + Host-Zeit, zu der er hörbar ist (mach_absolute_time)
    public var clockStamp: (beat: Double, hostTime: UInt64)? {
        var b = 0.0, h: UInt64 = 0
        guard mdsp_clock_stamp(core, &b, &h) else { return nil }
        return (b, h + LinkSession.hostTicks(seconds: output.outputLatency))
    }
    public func setMetronome(on: Bool, volume: Double, firstChannel: Int) {
        mdsp_metronome(core, on, Float(volume), Int32(firstChannel))
    }

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
