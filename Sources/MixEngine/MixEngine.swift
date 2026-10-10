import AVFoundation
import CoreAudio

/// Signalweg eines Decks:
/// Quelle → Varispeed (Tempo ohne Keylock) → TimePitch (Tempo mit Keylock, Key-Shift) → EQ/Filter/Gain
/// → FX-Unit 1 (Filter, Delay, Reverb) → FX-Unit 2 → Kanal (Fader/Crossfader) → Master
final class DeckChain {
    /// Eigene Engine pro Deck: so kann jedes Deck auf ein eigenes Kanalpaar des Geräts gehen (Externer Mixer).
    let engine = AVAudioEngine()
    let player = DeckPlayer()
    let source: AVAudioSourceNode
    let varispeed = AVAudioUnitVarispeed()
    let timePitch = AVAudioUnitTimePitch()
    /// Bänder: 0 Low, 1 Mid, 2 High, 3 Filter-LP, 4 Filter-HP
    let eq = AVAudioUnitEQ(numberOfBands: 5)
    var fx: [FXNodes] = []
    let channel = AVAudioMixerNode()

    init() {
        let p = player
        source = AVAudioSourceNode { _, _, frameCount, abl -> OSStatus in
            p.render(frameCount: Int(frameCount), abl: UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        let b = eq.bands
        b[0].filterType = .lowShelf; b[0].frequency = 100
        b[1].filterType = .parametric; b[1].frequency = 1000; b[1].bandwidth = 2
        b[2].filterType = .highShelf; b[2].frequency = 10000
        b[3].filterType = .resonantLowPass; b[3].frequency = 20000; b[3].bandwidth = 0.6
        b[4].filterType = .resonantHighPass; b[4].frequency = 20; b[4].bandwidth = 0.6
        for i in 0..<3 { b[i].gain = 0; b[i].bypass = false }
        b[3].bypass = true; b[4].bypass = true
        timePitch.bypass = true
        timePitch.overlap = 8
    }
}

/// Knoten einer FX-Unit für ein Deck.
final class FXNodes {
    let filter = AVAudioUnitEQ(numberOfBands: 2)
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()

    init() {
        filter.bands[0].filterType = .resonantLowPass
        filter.bands[1].filterType = .resonantHighPass
        for b in filter.bands { b.bypass = true; b.bandwidth = 0.25 }
        filter.bypass = true
        delay.bypass = true
        delay.lowPassCutoff = 9000
        reverb.bypass = true
        reverb.loadFactoryPreset(.largeHall)
    }
}

/// Die Audio-Engine: 4 Decks, interner Mixer, 2 FX-Units.
/// Jedes Deck hat eine eigene AVAudioEngine, deren Ausgang per Channel-Map auf ein Kanalpaar des Geräts geht.
/// Intern-Modus: alle Decks auf dasselbe Paar (CoreAudio summiert). Extern-Modus: jedes Deck eigenes Paar.
public final class MixEngine: @unchecked Sendable {
    public static let deckCount = 4
    public static let fxUnitCount = 2

    let chains: [DeckChain]
    /// Interne Samplerate der dekodierten Tracks (fest ab Start; die Engine wandelt zur Geräterate).
    public private(set) var sampleRate: Double = 44100
    public private(set) var running = false
    public private(set) var lastError: String?
    public private(set) var routing = Routing()

    /// Ausgangs-Zuordnung: Gerät + erster Kanal (0-basiert) des Stereopaars pro Deck.
    public struct Routing: Equatable, Sendable {
        public var device: AudioDeviceID?
        public var firstChannel: [Int] = [0, 0, 0, 0]
        public init(device: AudioDeviceID? = nil, firstChannel: [Int] = [0, 0, 0, 0]) {
            self.device = device
            self.firstChannel = firstChannel
        }
    }

    /// Wird gerufen, wenn CoreAudio eine Deck-Engine umkonfiguriert/stoppt (Gerät weg, Rate geändert …).
    public var onConfigurationChange: (@Sendable () -> Void)?
    private var observers: [NSObjectProtocol] = []

    public init() {
        chains = (0..<Self.deckCount).map { _ in DeckChain() }
        for c in chains {
            observers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: c.engine, queue: .main) { [weak self] _ in
                // Nur reagieren, wenn eine Engine wirklich steht (Gerät weg/Rate geändert) – nicht auf die
                // Meldungen, die das eigene Anwenden des Routings auslöst. Sonst gäbe es Aussetzer beim Spielen.
                guard let self, Date().timeIntervalSince(self.lastApply) > 2,
                      self.chains.contains(where: { !$0.engine.isRunning }) else { return }
                self.onConfigurationChange?()
            })
        }
        sampleRate = chains[0].engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate <= 0 { sampleRate = 44100 }
        build()
    }

    public func player(_ d: Int) -> DeckPlayer { chains[d].player }

    /// Pegel (RMS, Spitze) am Kanalausgang nach EQ/Filter/FX – für Anzeigen und Selbsttest
    public final class Level: @unchecked Sendable {
        public internal(set) var rms: Float = 0
        public internal(set) var peak: Float = 0
    }
    public let levels = (0..<MixEngine.deckCount).map { _ in Level() }

    private func build() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        for c in chains {
            let engine = c.engine
            c.fx = (0..<Self.fxUnitCount).map { _ in FXNodes() }
            var nodes: [AVAudioNode] = [c.source, c.varispeed, c.timePitch, c.eq]
            for f in c.fx { nodes += [f.filter, f.delay, f.reverb] }
            nodes.append(c.channel)
            nodes.forEach(engine.attach)
            for (a, b) in zip(nodes, nodes.dropFirst()) { engine.connect(a, to: b, format: fmt) }
            engine.connect(c.channel, to: engine.mainMixerNode, format: fmt)
        }
        for (d, c) in chains.enumerated() {
            let level = levels[d]
            c.channel.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
                guard let ch = buf.floatChannelData else { return }
                let n = Int(buf.frameLength)
                var sum: Float = 0, pk: Float = 0
                for i in 0..<n { let x = ch[0][i]; sum += x * x; pk = max(pk, abs(x)) }
                let rms = n > 0 ? (sum / Float(n)).squareRoot() : 0
                // Spitze mit Abfall, RMS geglättet
                level.peak = max(pk, level.peak * 0.85)
                level.rms = level.rms * 0.7 + rms * 0.3
            }
        }
    }

    public func start() { apply(routing) }

    public func stop() {
        chains.forEach { $0.engine.stop() }
        running = false
    }

    /// Gerät und Kanalpaare setzen; startet alle Deck-Engines neu.
    private var lastApply = Date.distantPast

    public func apply(_ r: Routing) {
        lastApply = Date()
        stop()
        routing = r
        var errors: [String] = []
        for (d, c) in chains.enumerated() {
            let engine = c.engine
            guard let unit = engine.outputNode.audioUnit else { continue }
            if var dev = r.device {
                let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
                if st != noErr { errors.append("Gerät (\(st))") }
            }
            // Echte Geräterate verwenden – sonst stellt CoreAudio das Gerät um (z. B. Xone auf 96 kHz),
            // was alle anderen Ausgänge auf dem Gerät stoppt.
            let devID = r.device ?? Self.defaultOutputDevice() ?? 0
            let devRate = Self.nominalRate(devID) ?? engine.outputNode.outputFormat(forBus: 0).sampleRate
            let devChannels = Int(engine.outputNode.outputFormat(forBus: 0).channelCount)
            // Stereo vom Mixer zum Ausgang; Channel-Map legt es auf das gewünschte Paar
            let stereo = AVAudioFormat(standardFormatWithSampleRate: devRate > 0 ? devRate : sampleRate, channels: 2)!
            engine.disconnectNodeInput(engine.outputNode)
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: stereo)
            let first = max(0, min(max(0, devChannels - 2), r.firstChannel[d]))
            var map = [Int32](repeating: -1, count: max(devChannels, 2))
            map[first] = 0
            map[first + 1] = 1
            let st = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                                          &map, UInt32(map.count * MemoryLayout<Int32>.size))
            if st != noErr { errors.append("Channel-Map Deck \(d + 1) (\(st))") }
            engine.prepare()
            do { try engine.start() } catch { errors.append("Start Deck \(d + 1): \(error.localizedDescription)") }
        }
        running = chains.allSatisfy { $0.engine.isRunning }
        lastError = errors.isEmpty ? nil : errors.joined(separator: " · ")
    }

    /// Anzahl Ausgangskanäle des aktuellen Geräts
    public var deviceChannels: Int { Int(chains[0].engine.outputNode.outputFormat(forBus: 0).channelCount) }

    // MARK: - Laden

    /// Tauscht die Audiodaten eines Decks. Das Deck wird dafür angehalten; der alte Puffer
    /// darf erst freigegeben werden, wenn der Audio-Thread ihn sicher nicht mehr liest (Aufrufer hält ihn ~100 ms).
    public func attach(_ audio: TrackAudio?, deck d: Int, startAt seconds: Double) {
        let p = chains[d].player
        p.playing = false
        p.frames = 0
        p.left = audio?.left
        p.right = audio?.right
        p.loopActive = false
        p.reverse = false
        p.reachedEnd = false
        p.pendingSeek = seconds * sampleRate
        p.frames = audio?.frames ?? 0
    }

    // MARK: - Transport

    public func seek(_ d: Int, seconds: Double) {
        chains[d].player.pendingSeek = max(0, seconds) * sampleRate
        chains[d].player.reachedEnd = false
    }

    public func position(_ d: Int) -> Double { chains[d].player.position / sampleRate }
    public func fluxPosition(_ d: Int) -> Double { chains[d].player.fluxPosition / sampleRate }

    public func setLoop(_ d: Int, active: Bool, start: Double, end: Double) {
        chains[d].player.pendingLoop = (active, start * sampleRate, end * sampleRate)
    }

    public func loop(_ d: Int) -> (active: Bool, start: Double, end: Double) {
        let p = chains[d].player
        return (p.loopActive, p.loopStart / sampleRate, p.loopEnd / sampleRate)
    }

    /// Tempo als Faktor (1 = Originaltempo). Keylock: Tonhöhe bleibt (TimePitch), sonst Varispeed.
    public func setRate(_ d: Int, rate: Double, keylock: Bool, keyShift: Double) {
        let c = chains[d]
        let r = Float(max(0.03, min(4, rate)))
        if keylock || keyShift != 0 {
            c.varispeed.rate = 1
            c.varispeed.bypass = true
            c.timePitch.bypass = false
            c.timePitch.rate = r
            c.timePitch.pitch = Float(keyShift * 100) + (keylock ? 0 : Float(1200 * log2(Double(r))))
        } else {
            c.timePitch.bypass = true
            c.varispeed.bypass = false
            c.varispeed.rate = r
        }
    }

    // MARK: - Mixer

    /// EQ in dB (−26 … +12; mit `kill` gilt ≤ −25 als ganz aus)
    public func setEQ(_ d: Int, low: Double, mid: Double, high: Double, kill: Bool = true) {
        let b = chains[d].eq.bands
        func g(_ v: Double) -> Float { Float(kill && v <= -25 ? -96 : v) }
        b[0].gain = g(low)
        b[1].gain = g(mid)
        b[2].gain = g(high)
    }

    /// Kanal-Gain in dB (Trim + Auto-Gain)
    public func setGain(_ d: Int, db: Double) {
        chains[d].eq.globalGain = Float(max(-24, min(24, db)))
    }

    /// Ein-Knopf-Filter wie in Traktor: −1 = Lowpass zu, 0 = aus, +1 = Highpass zu.
    public func setChannelFilter(_ d: Int, _ v: Double, resonance: Double = 0.6) {
        let b = chains[d].eq.bands
        applyFilter(lp: b[3], hp: b[4], v, bandwidth: resonance)
    }

    /// Kanal-Lautstärke 0–1 (Fader × Crossfader)
    public func setChannelVolume(_ d: Int, _ v: Double) {
        chains[d].channel.outputVolume = Float(max(0, min(1, v)))
    }

    public func setMasterVolume(_ v: Double) {
        for c in chains { c.engine.mainMixerNode.outputVolume = Float(max(0, min(1, v))) }
    }

    // MARK: - FX

    /// Delay-Zeiten in Beats (FXUnitState.delayIndex)
    public static let delayBeats: [Double] = [1.0 / 4, 1.0 / 2, 3.0 / 4, 1, 3.0 / 2, 2]

    /// Wendet eine FX-Unit (Gruppenmodus: Filter · Delay · Reverb) auf ein Deck an.
    public func applyFX(unit u: Int, deck d: Int, _ fx: FXUnitState, assigned: Bool, bpm: Double,
                        feedback: Double, filterResonance: Double) {
        let n = chains[d].fx[u]
        let wet = fx.dryWet
        // Slot 1: Filter (Knopf links = Lowpass, rechts = Highpass)
        let f = fx.slots[0]
        n.filter.bypass = !(assigned && f.on)
        if assigned && f.on {
            applyFilter(lp: n.filter.bands[0], hp: n.filter.bands[1], (f.amount * 2 - 1) * wet,
                        bandwidth: 0.9 - 0.8 * filterResonance)
        }
        // Slot 2: Delay (beat-synchron), Stärke = Wet + Feedback
        let dl = fx.slots[1]
        n.delay.bypass = !(assigned && dl.on)
        if assigned && dl.on {
            let idx = max(0, min(Self.delayBeats.count - 1, fx.delayIndex))
            let t = min(2, Self.delayBeats[idx] * 60 / (bpm > 0 ? bpm : 125))
            if abs(n.delay.delayTime - t) > 0.001 { n.delay.delayTime = t }
            n.delay.feedback = Float(feedback * 90 * (0.4 + 0.6 * dl.amount))
            n.delay.wetDryMix = Float(dl.amount * wet * 100)
        }
        // Slot 3: Reverb
        let rv = fx.slots[2]
        n.reverb.bypass = !(assigned && rv.on)
        if assigned && rv.on { n.reverb.wetDryMix = Float(rv.amount * wet * 100) }
    }

    /// Hallgröße (Preset) einer Unit auf allen Decks setzen
    public func setReverbSize(unit u: Int, _ size: Double) {
        let preset: AVAudioUnitReverbPreset = switch size {
            case ..<0.25: .mediumRoom
            case ..<0.5: .mediumHall
            case ..<0.75: .largeHall
            default: .cathedral
        }
        for c in chains { c.fx[u].reverb.loadFactoryPreset(preset) }
    }

    private func applyFilter(lp: AVAudioUnitEQFilterParameters, hp: AVAudioUnitEQFilterParameters,
                             _ v: Double, bandwidth: Double) {
        let dead = 0.02
        if v < -dead {
            lp.bypass = false; hp.bypass = true
            lp.frequency = Float(20000 * pow(60.0 / 20000, -v))
            lp.bandwidth = Float(bandwidth)
        } else if v > dead {
            hp.bypass = false; lp.bypass = true
            hp.frequency = Float(25 * pow(9000.0 / 25, v))
            hp.bandwidth = Float(bandwidth)
        } else {
            lp.bypass = true; hp.bypass = true
        }
    }

    // MARK: - Ausgabegerät

    public struct OutputDevice: Identifiable, Hashable, Sendable {
        public let id: AudioDeviceID
        /// bleibt über Neustarts gleich (IDs nicht)
        public let uid: String
        public let name: String
        public let channels: Int
    }

    static func nominalRate(_ id: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard id != 0, AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }

    /// aktuelles Standard-Ausgabegerät des Systems
    public static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return id
    }

    public static func outputDevices() -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            let ch = channelCount(id)
            guard ch > 0 else { return nil }
            return OutputDevice(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                                name: stringProperty(id, kAudioObjectPropertyName), channels: ch)
        }
    }

    static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name) == noErr, let n = name else { return "?" }
        return n.takeRetainedValue() as String
    }

    static func channelCount(_ id: AudioDeviceID) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
