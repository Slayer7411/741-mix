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

    /// startet die Ausgabe auf `device` (nil = Systemstandard) mit allen Ausgangskanälen des Geräts
    func start(device: AudioDeviceID?, engine: OpaquePointer, bufferFrames: UInt32?) throws {
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
        deviceRate = MixEngine.nominalRate(dev) ?? 44100
        if var frames = bufferFrames {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        }
        // Float32, nicht verschachtelt, alle Kanäle des Geräts, Geräterate (nie die Rate des Geräts ändern)
        var fmt = AudioStreamBasicDescription(mSampleRate: deviceRate, mFormatID: kAudioFormatLinearPCM,
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

    private func err(_ s: String) -> NSError { NSError(domain: "741mix.audio", code: 1, userInfo: [NSLocalizedDescriptionKey: s]) }
    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw NSError(domain: "741mix.audio", code: Int(st), userInfo: [NSLocalizedDescriptionKey: "\(what) (\(st))"]) }
    }
}
