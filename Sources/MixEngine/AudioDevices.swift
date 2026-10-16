import CoreAudio

/// Geräteliste und Geräte-Eigenschaften (CoreAudio HAL)
extension MixEngine {
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

    /// Gerät vorhanden und betriebsbereit (kAudioDevicePropertyDeviceIsAlive)
    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return id != 0 && AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr && v != 0
    }

    /// Ausgabegerät zur UID (nil = nicht da oder ohne Ausgangskanäle)
    static func device(uid: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString, id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard st == noErr, id != kAudioObjectUnknown, channelCount(id) > 0 else { return nil }
        return id
    }

    /// Raten, die das Gerät kann (aus den Bereichen die üblichen Werte)
    public static func availableRates(_ id: AudioDeviceID) -> [Double] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard id != 0, AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        return [44100.0, 48000, 88200, 96000, 176400, 192000].filter { r in ranges.contains { $0.mMinimum <= r && r <= $0.mMaximum } }
    }

    /// Puffergrößen, die das Gerät annimmt (Frames); nil wenn nicht lesbar
    public static func bufferFrameRange(_ id: AudioDeviceID) -> ClosedRange<Int>? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSizeRange,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var r = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard id != 0, AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &r) == noErr,
              r.mMinimum >= 1, r.mMaximum >= r.mMinimum else { return nil }
        return Int(r.mMinimum)...Int(min(r.mMaximum, Double(1 << 20)))
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

    // MARK: - Eingang (Aufnahme)

    /// Geräte mit Eingangskanälen (Aufnahme vom Pult): ID, UID, Name, Eingangskanäle
    public static func inputDevices() -> [OutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.compactMap { id in
            let ch = channelCount(id, scope: kAudioDevicePropertyScopeInput)
            guard ch > 0 else { return nil }
            return OutputDevice(id: id, uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                                name: stringProperty(id, kAudioObjectPropertyName), channels: ch)
        }
    }

    /// Eingangsgerät zur UID (nil = nicht da oder ohne Eingangskanäle)
    public static func inputDevice(uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString, id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        guard st == noErr, id != kAudioObjectUnknown, channelCount(id, scope: kAudioDevicePropertyScopeInput) > 0 else { return nil }
        return id
    }

    /// Eingangskanäle eines Geräts
    public static func inputChannels(_ id: AudioDeviceID) -> Int { channelCount(id, scope: kAudioDevicePropertyScopeInput) }
    /// Nennrate eines Geräts (nil = unbekannt)
    public static func deviceRate(_ id: AudioDeviceID) -> Double? { nominalRate(id) }
    /// UID eines Geräts
    public static func deviceUID(_ id: AudioDeviceID) -> String { stringProperty(id, kAudioDevicePropertyDeviceUID) }

    static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope,
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
