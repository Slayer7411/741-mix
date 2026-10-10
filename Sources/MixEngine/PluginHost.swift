import AudioToolbox
import Foundation
import MixDSP

/// Installiertes Effekt-Plugin (Audio Unit "aufx"/"aumf", v2 oder v3 über die Bridge)
public struct PluginInfo: Identifiable, Hashable, Sendable {
    /// "type:subtype:manu" als FourCC-Text, z. B. "aufx:mrev:appl"
    public let id: String
    public let name: String
    public let manufacturer: String
    public let type: UInt32, subtype: UInt32, manu: UInt32
    /// Komponenten-Version (0xMMMMmmbb)
    public var version: UInt32 = 0
    /// AUv3 (App-Erweiterung)
    public var isV3 = false

    public init(id: String, name: String, manufacturer: String, type: UInt32, subtype: UInt32, manu: UInt32,
                version: UInt32 = 0, isV3: Bool = false) {
        self.id = id; self.name = name; self.manufacturer = manufacturer
        self.type = type; self.subtype = subtype; self.manu = manu
        self.version = version; self.isV3 = isV3
    }

    /// von Apple (Hersteller "appl") – läuft immer im Prozess
    public var isApple: Bool { manu == 0x6170706c }
    /// "1.6.0"
    public var versionString: String { PluginHost.versionString(version) }
}

public enum PluginHost {
    /// alle installierten Effekt-Plugins, sortiert nach Hersteller und Name
    public static func installed() -> [PluginInfo] {
        var out: [PluginInfo] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            var desc = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0,
                                                 componentFlags: 0, componentFlagsMask: 0)
            var comp = AudioComponentFindNext(nil, &desc)
            while let c = comp {
                var d = AudioComponentDescription()
                if AudioComponentGetDescription(c, &d) == noErr {
                    var cf: Unmanaged<CFString>?
                    AudioComponentCopyName(c, &cf)
                    let full = cf?.takeRetainedValue() as String? ?? fourCC(d.componentSubType)
                    // "Hersteller: Name"
                    let parts = full.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let (manu, name) = parts.count == 2 ? (parts[0], parts[1]) : (fourCC(d.componentManufacturer), full)
                    var v: UInt32 = 0
                    AudioComponentGetVersion(c, &v)
                    out.append(PluginInfo(id: id(d.componentType, d.componentSubType, d.componentManufacturer), name: name,
                                          manufacturer: manu, type: d.componentType, subtype: d.componentSubType,
                                          manu: d.componentManufacturer, version: v,
                                          isV3: d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0))
                }
                comp = AudioComponentFindNext(c, &desc)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
            .sorted { ($0.manufacturer.lowercased(), $0.name.lowercased()) < ($1.manufacturer.lowercased(), $1.name.lowercased()) }
    }

    public static func id(_ t: UInt32, _ s: UInt32, _ m: UInt32) -> String { "\(fourCC(t)):\(fourCC(s)):\(fourCC(m))" }

    /// "aufx:mrev:appl" → Codes
    public static func codes(_ id: String) -> (UInt32, UInt32, UInt32)? {
        let p = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard p.count == 3, let t = code(p[0]), let s = code(p[1]), let m = code(p[2]) else { return nil }
        return (t, s, m)
    }

    public static func versionString(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xff).\(v & 0xff)" }

    public static func fourCC(_ v: UInt32) -> String {
        let b = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: b, encoding: .macOSRoman) ?? String(format: "%08x", v)
    }

    public static func code(_ s: String) -> UInt32? {
        guard let d = s.data(using: .macOSRoman), d.count == 4 else { return nil }
        return d.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Eine geöffnete Plugin-Instanz (für genau eine FX-Unit × Deck). Schließt beim Freigeben –
/// die Engine hält sie, bis der Audio-Thread sie nicht mehr rechnet.
public final class PluginInstance: @unchecked Sendable {
    public struct Parameter: Sendable, Equatable {
        public let id: AudioUnitParameterID
        public let name: String
        public let min: Float, max: Float, defaultValue: Float
    }

    public let info: PluginInfo
    let ptr: OpaquePointer
    public let audioUnit: AudioUnit
    /// läuft isoliert in einem Systemdienst (Absturz trifft nur den Dienst, nicht MINOS-741)
    public let outOfProcess: Bool
    /// beschreibbare Parameter (globaler Scope)
    public private(set) lazy var parameters: [Parameter] = readParameters()

    /// öffnen (blockiert bis zu `timeout` s – nie auf dem Audio-Thread aufrufen). `outOfProcess`: über
    /// AudioComponentInstantiate mit kAudioComponentInstantiation_LoadOutOfProcess (v2 und v3, macOS 11+)
    public init(_ info: PluginInfo, sampleRate: Double, outOfProcess: Bool = false, timeout: Double = 10) throws {
        self.info = info
        self.outOfProcess = outOfProcess
        var err = [CChar](repeating: 0, count: 256)
        let fail = { (why: String) in
            NSError(domain: "minos741.plugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(info.name): \(why)"])
        }
        let opened: OpaquePointer?
        if outOfProcess {
            let au = try Self.instantiate(info, options: .loadOutOfProcess, timeout: timeout, fail: fail)
            opened = mdplug_wrap(UnsafeMutableRawPointer(au), sampleRate, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count))
        } else {
            opened = mdplug_open(info.type, info.subtype, info.manu, sampleRate, UInt32(MDSP_MAX_FRAMES), &err, Int32(err.count))
        }
        guard let p = opened, let raw = mdplug_audio_unit(p) else { throw fail(String(cString: err)) }
        ptr = p
        audioUnit = AudioUnit(OpaquePointer(raw))
    }

    /// asynchron anlegen und auf das Ergebnis warten; kommt es nach dem Zeitlimit, wird es gleich wieder geschlossen
    private static func instantiate(_ info: PluginInfo, options: AudioComponentInstantiationOptions, timeout: Double,
                                    fail: (String) -> NSError) throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: info.type, componentSubType: info.subtype,
                                             componentManufacturer: info.manu, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw fail("audio unit not installed") }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var unit: AudioUnit?
            var status: OSStatus = noErr
            var abandoned = false
        }
        let box = Box(), done = DispatchSemaphore(value: 0)
        AudioComponentInstantiate(comp, options) { unit, st in
            box.lock.lock(); defer { box.lock.unlock() }
            if box.abandoned { if let unit { AudioComponentInstanceDispose(unit) }; return }
            box.unit = unit; box.status = st
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            box.lock.lock(); defer { box.lock.unlock() }
            if let u = box.unit { return u }   // genau an der Grenze fertig geworden
            box.abandoned = true
            throw fail("instantiate timed out")
        }
        guard box.status == noErr, let u = box.unit else { throw fail("instance failed (\(box.status))") }
        return u
    }

    /// Latenz des Plugins in Sekunden (kAudioUnitProperty_Latency)
    public var latency: Double {
        var v: Float64 = 0
        var s = UInt32(MemoryLayout<Float64>.size)
        return AudioUnitGetProperty(audioUnit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &v, &s) == noErr ? v : 0
    }

    /// einen Block durch das Plugin rechnen (Messungen, Tests; im Betrieb rechnet der Kern)
    public func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
        mdplug_process(ptr, l, r, Int32(n))
    }

    deinit {
        stopObserving()
        mdplug_close(ptr)
    }

    private var listener: AUParameterListenerRef?

    /// Parameteränderungen (Plugin-Fenster, Automation) melden – auf `queue`, höchstens alle 30 ms je Parameter
    public func observe(on queue: DispatchQueue, _ f: @escaping @Sendable (AudioUnitParameterID, Float) -> Void) {
        stopObserving()
        var l: AUParameterListenerRef?
        guard AUListenerCreateWithDispatchQueue(&l, 0.03, queue, { _, p, v in f(p.pointee.mParameterID, v) }) == noErr,
              let l else { return }
        for p in parameters {
            var ap = AudioUnitParameter(mAudioUnit: audioUnit, mParameterID: p.id, mScope: kAudioUnitScope_Global, mElement: 0)
            AUListenerAddParameter(l, nil, &ap)
        }
        listener = l
    }

    public func stopObserving() {
        if let l = listener { AUListenerDispose(l); listener = nil }
    }

    public func reset() { mdplug_reset(ptr) }

    private func readParameters() -> [Parameter] {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(audioUnit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size > 0 else { return [] }
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / MemoryLayout<AudioUnitParameterID>.size)
        guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size) == noErr else { return [] }
        return ids.compactMap { id in
            var pi = AudioUnitParameterInfo()
            var s = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &pi, &s) == noErr,
                  pi.flags.contains(.flag_IsWritable) else { return nil }
            var name = ""
            if pi.flags.contains(.flag_HasCFNameString), let cf = pi.cfNameString {
                name = cf.takeUnretainedValue() as String
                if pi.flags.contains(.flag_CFNameRelease) { cf.release() }
            } else {
                name = withUnsafeBytes(of: pi.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            }
            return Parameter(id: id, name: name, min: pi.minValue, max: pi.maxValue, defaultValue: pi.defaultValue)
        }
    }

    public func value(_ id: AudioUnitParameterID) -> Float {
        var v: AudioUnitParameterValue = 0
        AudioUnitGetParameter(audioUnit, id, kAudioUnitScope_Global, 0, &v)
        return v
    }

    /// setzen und Zuhörer (Plugin-Fenster) benachrichtigen
    public func set(_ id: AudioUnitParameterID, _ v: Float) {
        var p = AudioUnitParameter(mAudioUnit: audioUnit, mParameterID: id, mScope: kAudioUnitScope_Global, mElement: 0)
        AUParameterSet(nil, nil, &p, v, 0)
    }

    /// Regler 0…1 auf den i-ten beschreibbaren Parameter (min…max)
    public func setKnob(_ i: Int, _ v: Double) {
        guard i < parameters.count else { return }
        let p = parameters[i]
        set(p.id, p.min + Float(max(0, min(1, v))) * (p.max - p.min))
    }

    /// Stellung des i-ten Parameters als 0…1
    public func knob(_ i: Int) -> Double? {
        guard i < parameters.count else { return nil }
        let p = parameters[i]
        return p.max > p.min ? Double((value(p.id) - p.min) / (p.max - p.min)) : nil
    }

    /// kompletter Zustand (ClassInfo) als Binär-Plist
    public var state: Data? {
        get {
            var ref: Unmanaged<CFPropertyList>?
            var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
            guard AudioUnitGetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0, &ref, &size) == noErr,
                  let plist = ref?.takeRetainedValue() else { return nil }
            return try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        }
        set {
            guard let d = newValue,
                  let obj = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) else { return }
            let plist = obj as CFPropertyList
            // Wert der Eigenschaft ist der CFPropertyListRef selbst
            var ref: UnsafeRawPointer? = UnsafeRawPointer(Unmanaged.passUnretained(plist).toOpaque())
            let st = withExtendedLifetime(plist) {
                AudioUnitSetProperty(audioUnit, kAudioUnitProperty_ClassInfo, kAudioUnitScope_Global, 0,
                                     &ref, UInt32(MemoryLayout<UnsafeRawPointer>.size))
            }
            guard st == noErr else { return }
            // Ansichten neu einlesen lassen
            var any = AudioUnitParameter(mAudioUnit: audioUnit, mParameterID: kAUParameterListener_AnyParameter,
                                         mScope: kAudioUnitScope_Global, mElement: 0)
            AUParameterListenerNotify(nil, nil, &any)
        }
    }
}
