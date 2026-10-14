import AudioToolbox
import CoreAudio
import Foundation
import MixDSP

/// Eingang für die Aufnahme: eigenes AUHAL nur mit Eingang (Bus 1) auf dem gewählten Gerät, Callback in C++
/// (mdsp_input_callback) schreibt das Eingangspaar in einen Ring. Die Ausgabe bleibt unberührt (kein Neu-Initialisieren
/// des Ausgangs, keine Puffergröße gesetzt). Gleiches Gerät wie die Ausgabe: derselbe IO-Takt; anderes Gerät: eigener
/// Takt, die Datei bekommt dessen Rate. Start/Stop auf einem Thread (Hauptthread der App).
public final class CoreAudioInput: @unchecked Sendable {
    public struct Info: Sendable, Equatable {
        public var device: AudioDeviceID = 0
        public var uid = ""
        public var name = ""
        public var rate: Double = 0
        public var channels = 0
        public var firstChannel = 0
    }

    public enum Event: Sendable, Equatable { case alive(Bool), rate(Double) }
    /// Meldungen des Geräts (Queue `eventQueue`)
    public var onEvent: (@Sendable (Event) -> Void)?

    public enum InputError: Error, Equatable, LocalizedError {
        case noDevice, noChannels(Int), setup(String, OSStatus)
        public var errorDescription: String? {
            switch self {
            case .noDevice: String(localized: "Eingangsgerät nicht da")
            case let .noChannels(n): String(localized: "Gerät hat nur \(n) Eingangskanäle")
            case let .setup(what, st): "\(what) (\(st))"
            }
        }
    }

    private var unit: AudioUnit?
    private var tap: OpaquePointer?
    private var ring: RecordRing?
    public private(set) var info: Info?
    private let eventQueue: DispatchQueue
    private var listeners: [(AudioDeviceID, AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []

    public init(eventQueue: DispatchQueue = DispatchQueue(label: "minos741.input", qos: .userInitiated)) {
        self.eventQueue = eventQueue
    }

    deinit { stop() }

    public var running: Bool { unit != nil }

    /// Eingang von `device` (Paar ab `firstChannel`) in `ring` starten
    @discardableResult
    public func start(device: AudioDeviceID?, firstChannel: Int, ring: RecordRing) throws -> Info {
        stop()
        do { return try open(device, firstChannel, ring) } catch { stop(); throw error }
    }

    private func open(_ device: AudioDeviceID?, _ first: Int, _ ring: RecordRing) throws -> Info {
        guard var dev = device, MixEngine.isAlive(dev) else { throw InputError.noDevice }
        let channels = MixEngine.inputChannels(dev)
        guard channels > 0 else { throw InputError.noDevice }
        guard first >= 0, first < channels else { throw InputError.noChannels(channels) }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw InputError.setup("AUHAL", -1) }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AUHAL anlegen")
        guard let au = u else { throw InputError.setup("AUHAL", -1) }
        unit = au
        var on: UInt32 = 1, off: UInt32 = 0
        let size32 = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size32), "Eingang an")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size32), "Ausgang aus")
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "Gerät setzen")
        // Rate des Geräts (Eingang wird nicht umgerechnet), alle Eingangskanäle, Float32 nicht verschachtelt
        var hw = AudioStreamBasicDescription(), asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &asbdSize), "Format lesen")
        let rate = hw.mSampleRate > 0 ? hw.mSampleRate : (MixEngine.nominalRate(dev) ?? 48000)
        var fmt = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt, asbdSize), "Format")
        // größter Block fest (wie der Ausgang): sonst gilt der Gerätepuffer beim Initialisieren, ein größerer danach scheitert
        var maxFrames = UInt32(MDSP_MAX_FRAMES), mfSize = size32
        AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, size32)
        AudioUnitGetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &mfSize)
        guard let t = mdsp_input_create(Int32(channels), Int32(max(4096, Int(maxFrames)))) else { throw InputError.setup("Puffer", -1) }
        tap = t
        var cb = AURenderCallbackStruct(inputProc: mdsp_input_callback(), inputProcRefCon: UnsafeMutableRawPointer(t))
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Callback")
        try check(AudioUnitInitialize(au), "Initialisieren")
        mdsp_input_set(t, au, ring.ptr, Int32(first))
        self.ring = ring
        try check(AudioOutputUnitStart(au), "Starten")
        let i = Info(device: dev, uid: MixEngine.stringProperty(dev, kAudioDevicePropertyDeviceUID),
                     name: MixEngine.stringProperty(dev, kAudioObjectPropertyName), rate: rate, channels: channels, firstChannel: first)
        info = i
        listen(dev)
        return i
    }

    public func stop() {
        removeListeners()
        if let au = unit {
            AudioOutputUnitStop(au)   // wartet, bis der Callback durch ist
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
            unit = nil
        }
        if let t = tap { mdsp_input_destroy(t); tap = nil }
        ring = nil
        info = nil
    }

    /// Callback seit dem letzten Abholen: Blöcke, mittlere / längste Zeit (ms), Fehler von AudioUnitRender
    public func takeStats() -> (blocks: Int, averageMs: Double, worstMs: Double, errors: Int) {
        guard let t = tap else { return (0, 0, 0, 0) }
        let s = mdsp_input_take_stats(t)
        return (Int(s.blocks), s.blocks > 0 ? Double(s.totalNs) / Double(s.blocks) / 1e6 : 0, Double(s.worstNs) / 1e6,
                Int(s.renderErrors))
    }

    private func listen(_ dev: AudioDeviceID) {
        func add(_ sel: AudioObjectPropertySelector, _ f: @escaping @Sendable () -> Void) {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in f() }
            if AudioObjectAddPropertyListenerBlock(dev, &addr, eventQueue, block) == noErr { listeners.append((dev, sel, block)) }
        }
        add(kAudioDevicePropertyDeviceIsAlive) { [weak self] in self?.onEvent?(.alive(MixEngine.isAlive(dev))) }
        add(kAudioDevicePropertyNominalSampleRate) { [weak self] in
            if let r = MixEngine.nominalRate(dev) { self?.onEvent?(.rate(r)) }
        }
    }

    private func removeListeners() {
        for (dev, sel, block) in listeners {
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(dev, &addr, eventQueue, block)
        }
        listeners.removeAll()
    }

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw InputError.setup(what, st) }
    }
}
