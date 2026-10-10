import AudioToolbox
import CoreAudio
import MixDSP

/// Ein einziger CoreAudio-Ausgang (AUHAL) direkt auf dem Gerät. Der Render-Callback ist C++ (mdsp_au_render) –
/// im Audio-Thread läuft kein Swift.
final class CoreAudioOutput {
    private var unit: AudioUnit?
    private(set) var channels = 2
    private(set) var deviceRate: Double = 44100
    private(set) var running = false
    /// Zeit vom Render-Callback bis zum Ausgang (Puffer + Geräte-, Sicherheits- und Stream-Latenz), Sekunden
    private(set) var outputLatency: Double = 0

    /// startet die Ausgabe auf `device` (nil = Systemstandard) mit allen Ausgangskanälen des Geräts
    /// `engineRate` = Rate des Kerns (AUHAL rechnet um, falls das Gerät anders läuft);
    /// `deviceRate` gesetzt = Gerät auf diese Rate stellen (wie im Audio-Setup üblich)
    func start(device: AudioDeviceID?, engine: OpaquePointer, engineRate: Double, bufferFrames: UInt32?, setDeviceRate: Double?) throws {
        stop()
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw err("kein AUHAL") }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "AUHAL anlegen")
        guard let au = u else { throw err("AUHAL nil") }
        unit = au

        var dev = device ?? MixEngine.defaultOutputDevice() ?? 0
        try check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                       &dev, UInt32(MemoryLayout<AudioDeviceID>.size)), "Gerät setzen")
        channels = max(2, MixEngine.channelCount(dev))
        if let want = setDeviceRate, MixEngine.availableRates(dev).contains(want), MixEngine.nominalRate(dev) != want {
            var r = Float64(want)
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &r)
            for _ in 0..<50 where MixEngine.nominalRate(dev) != want { usleep(10_000) }   // Gerät schaltet asynchron um
        }
        deviceRate = MixEngine.nominalRate(dev) ?? 44100
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
        try check(AudioUnitInitialize(au), "Initialisieren")
        try check(AudioOutputUnitStart(au), "Starten")
        running = true
        outputLatency = Double(Self.latencyFrames(dev)) / deviceRate
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

    func stop() {
        guard let au = unit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        unit = nil
        running = false
    }

    deinit { stop() }

    private func err(_ s: String) -> NSError { NSError(domain: "minos741.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw NSError(domain: "minos741.audio", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(st))"]) }
    }
}
