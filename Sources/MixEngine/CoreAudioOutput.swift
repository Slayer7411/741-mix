import AudioToolbox
import CoreAudio
import Foundation
import MixCore
import MixDSP

/// Ein einziger CoreAudio-Ausgang (AUHAL) direkt auf dem Gerät. Der Render-Callback ist C++ (mdsp_au_render) –
/// im Audio-Thread läuft kein Swift. Start/Stop nur auf der Geräte-Queue der Engine; die Werte (`info`) von jedem Thread.
final class CoreAudioOutput: @unchecked Sendable {
    struct Info: Sendable {
        var channels = 2
        var deviceRate: Double = 44100
        var running = false
        /// Zeit vom Render-Callback bis zum Ausgang (Puffer + Geräte-, Sicherheits- und Stream-Latenz), Sekunden
        var outputLatency: Double = 0
        /// tatsächliche Puffergröße des Geräts (Frames)
        var bufferFrameSize: UInt32 = 0
        var device: AudioDeviceID = 0
        /// bleibt über Aus-/Einstecken gleich (die ID nicht)
        var uid = ""
        var name = ""
    }

    /// Meldungen des laufenden Geräts, auf der Queue aus `init`
    enum DeviceEvent: Sendable { case alive(Bool), rate(Double), buffer(UInt32) }
    var onDeviceEvent: (@Sendable (DeviceEvent) -> Void)?

    private var unit: AudioUnit?
    private var engine: OpaquePointer?
    private let infoLock = NSLock()
    private var _info = Info()
    var info: Info { infoLock.withLock { _info } }
    var channels: Int { info.channels }
    var deviceRate: Double { info.deviceRate }
    var running: Bool { info.running }
    var outputLatency: Double { info.outputLatency }
    var bufferFrameSize: UInt32 { info.bufferFrameSize }

    /// Überlastmeldungen des Geräts (kAudioDeviceProcessorOverload) seit Start/Zurücksetzen
    var deviceOverloads: Int { overloadLock.withLock { overloadCount } }
    func resetDeviceOverloads() { overloadLock.withLock { overloadCount = 0 } }
    private let overloadLock = NSLock()
    private var overloadCount = 0
    private let overloadQueue = DispatchQueue(label: "minos741.overload", qos: .utility)
    private let eventQueue: DispatchQueue
    /// angemeldete Listener (Gerät, Selektor, Queue, Block) – beim Stop wieder ab
    private var listeners: [(AudioDeviceID, AudioObjectPropertySelector, DispatchQueue, AudioObjectPropertyListenerBlock)] = []

    init(eventQueue: DispatchQueue) { self.eventQueue = eventQueue }

    /// startet die Ausgabe auf `device` (nil = Systemstandard) mit allen Ausgangskanälen des Geräts
    /// `engineRate` = Rate des Kerns (AUHAL rechnet um, falls das Gerät anders läuft);
    /// `deviceRate` gesetzt = Gerät auf diese Rate stellen (wie im Audio-Setup üblich)
    func start(device: AudioDeviceID?, engine: OpaquePointer, engineRate: Double, bufferFrames: UInt32?, setDeviceRate: Double?) throws {
        stop()
        do { try open(device, engine, engineRate, bufferFrames, setDeviceRate) } catch { stop(); throw error }
    }

    private func open(_ device: AudioDeviceID?, _ engine: OpaquePointer, _ engineRate: Double, _ bufferFrames: UInt32?,
                      _ setDeviceRate: Double?) throws {
        // Ende-zu-Ende (MIX741_E2E_ROOT): kein Gerät anfassen, der Kern rendert im eigenen Takt (startNull)
        if E2E.isActive { startNull(engine, engineRate, bufferFrames); return }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("kein AUHAL") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AUHAL anlegen")
        guard let au = u else { throw err("AUHAL nil") }
        unit = au

        var dev = device ?? MixEngine.defaultOutputDevice() ?? 0
        guard MixEngine.isAlive(dev) else { throw err("Gerät nicht bereit") }
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "Gerät setzen")
        let channels = max(2, MixEngine.channelCount(dev))
        if let want = setDeviceRate, MixEngine.availableRates(dev).contains(want), MixEngine.nominalRate(dev) != want {
            var r = Float64(want)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
            for _ in 0..<50 where MixEngine.nominalRate(dev) != want { usleep(10_000) }   // Gerät schaltet asynchron um
        }
        if var frames = bufferFrames {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        }
        // Float32, nicht verschachtelt, alle Kanäle des Geräts, Rate des Kerns
        var fmt = AudioStreamBasicDescription(mSampleRate: engineRate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                       &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Format")
        var cb = AURenderCallbackStruct(inputProc: mdsp_render_callback(), inputProcRefCon: UnsafeMutableRawPointer(engine))
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Callback")
        // größter Block, den der AUHAL rendert: fest statt aus dem Gerätepuffer beim Initialisieren. Sonst bleibt er auf dem
        // alten Puffer stehen, wenn das Gerät die neue Größe erst danach übernimmt (256 -> 512: jeder Zyklus endet mit
        // kAudioUnitErr_TooManyFramesToProcess, der Callback kommt nie, die Ausgabe ist still), ebenso bei einem größeren
        // Puffer von außen. Der Kern rechnet größere Blöcke in Teilen
        var maxFrames = UInt32(max(Int(MDSP_MAX_FRAMES), Int(bufferFrames ?? 0) * 2))
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &maxFrames, UInt32(MemoryLayout<UInt32>.size)), "Blockgröße")
        mdsp_load_set_rate(engineRate)   // DSP-Last: Blöcke kommen mit der Rate des Kerns
        try check(AudioUnitInitialize(au), "Initialisieren")
        // Worker der parallelen Decks: Workgroup des IO-Threads (erst nach dem Initialisieren vorhanden), Blockdauer des Geräts
        self.engine = engine
        mdsp_au_join_workgroup(engine, au, Double(Self.bufferFrames(dev)) / (MixEngine.nominalRate(dev) ?? engineRate))
        // vor dem Start als laufend melden: der erste Callback kann kommen, bevor Start zurückkehrt (Freigaben warten dann
        // auf den Kern statt auf `running`); scheitert der Start, setzt stop() es zurück
        infoLock.withLock { _info.running = true }
        try check(AudioOutputUnitStart(au), "Starten")
        let rate = MixEngine.nominalRate(dev) ?? 44100
        infoLock.withLock {
            _info = Info(channels: channels, deviceRate: rate, running: true,
                         outputLatency: Double(Self.latencyFrames(dev)) / rate, bufferFrameSize: Self.bufferFrames(dev),
                         device: dev, uid: MixEngine.stringProperty(dev, kAudioDevicePropertyDeviceUID),
                         name: MixEngine.stringProperty(dev, kAudioObjectPropertyName))
        }
        listen(dev)
    }

    /// Rate, Puffer und Latenz des laufenden Geräts neu lesen (nach einer Änderung von außen)
    func refresh() {
        let dev = info.device
        guard running, dev != 0 else { return }
        let rate = MixEngine.nominalRate(dev) ?? info.deviceRate
        let lat = Double(Self.latencyFrames(dev)) / rate, buf = Self.bufferFrames(dev)
        infoLock.withLock { _info.deviceRate = rate; _info.outputLatency = lat; _info.bufferFrameSize = buf }
        if let au = unit, let engine { mdsp_au_join_workgroup(engine, au, Double(buf) / rate) }   // Worker: neue Periode
    }

    static func bufferFrames(_ dev: AudioDeviceID) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &v) == noErr ? v : 0
    }

    /// Geräte-Überlast zählen (HAL meldet einen verpassten Zyklus); Lebenszeichen, Rate und Puffer des Geräts melden.
    /// Die Blöcke laufen auf den Queues (nie im Audio- oder HAL-Thread) und lesen nur den neuen Wert
    private func listen(_ dev: AudioDeviceID) {
        add(dev, kAudioDeviceProcessorOverload, overloadQueue) { [weak self] in
            guard let self else { return }
            self.overloadLock.withLock { self.overloadCount += 1 }
        }
        add(dev, kAudioDevicePropertyDeviceIsAlive, eventQueue) { [weak self] in
            self?.onDeviceEvent?(.alive(MixEngine.isAlive(dev)))
        }
        add(dev, kAudioDevicePropertyNominalSampleRate, eventQueue) { [weak self] in
            if let r = MixEngine.nominalRate(dev) { self?.onDeviceEvent?(.rate(r)) }
        }
        add(dev, kAudioDevicePropertyBufferFrameSize, eventQueue) { [weak self] in
            self?.onDeviceEvent?(.buffer(Self.bufferFrames(dev)))
        }
    }

    private func add(_ dev: AudioDeviceID, _ sel: AudioObjectPropertySelector, _ q: DispatchQueue, _ f: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in f() }
        if AudioObjectAddPropertyListenerBlock(dev, &addr, q, block) == noErr { listeners.append((dev, sel, q, block)) }
    }

    private func removeListeners() {
        for (dev, sel, q, block) in listeners {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(dev, &addr, q, block)
        }
        listeners.removeAll()
    }

    private static func latencyFrames(_ dev: AudioDeviceID) -> UInt32 {
        func get(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        var n = get(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
            + get(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        if AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var first = AudioStreamID(0); size = UInt32(MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &first) == noErr {
                n += get(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return n
    }

    /// Ende-zu-Ende: Zwischenpuffer-Ausgabe ohne Gerät. Ein Timer auf eigener Queue rendert Blöcke der Puffergröße in
    /// Echtzeit (`mdsp_render`), so laufen Position, Wiedergabe und Analyse wie mit Gerät, nur ohne Ton
    private var nullTimer: DispatchSourceTimer?
    private let nullQueue = DispatchQueue(label: "minos741.e2e.null", qos: .userInitiated)

    private func startNull(_ engine: OpaquePointer, _ engineRate: Double, _ bufferFrames: UInt32?) {
        let frames = max(16, Int(bufferFrames ?? 512))
        self.engine = engine
        infoLock.withLock {
            _info = Info(channels: 2, deviceRate: engineRate, running: true, outputLatency: Double(frames) / engineRate,
                         bufferFrameSize: UInt32(frames), device: 0, uid: E2E.nullDeviceUID, name: E2E.nullDeviceName)
        }
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let outs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        outs[0] = left
        outs[1] = right
        let t = DispatchSource.makeTimerSource(queue: nullQueue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(Int(Double(frames) / engineRate * 1e9)), leeway: .microseconds(50))
        t.setEventHandler {
            mdsp_set_render_host(engine, mach_absolute_time())
            mdsp_render(engine, outs, 2, Int32(frames))
        }
        // Speicher erst nach dem letzten Block freigeben (stopNull wartet auf die Queue)
        t.setCancelHandler { left.deallocate(); right.deallocate(); outs.deallocate() }
        nullTimer = t
        t.resume()
    }

    private func stopNull() {
        guard let t = nullTimer else { return }
        nullTimer = nil
        t.cancel()
        nullQueue.sync {}
        infoLock.withLock { _info.running = false }
    }

    func stop() {
        removeListeners()
        stopNull()
        guard let au = unit else { return }
        AudioOutputUnitStop(au)   // wartet, bis der Render-Callback durch ist
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        infoLock.withLock { _info.running = false }
    }

    deinit { stop() }

    private func err(_ s: String) -> NSError { NSError(domain: "minos741.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw NSError(domain: "minos741.audio", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(st))"]) }
    }
}
