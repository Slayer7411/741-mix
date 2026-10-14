import AudioToolbox
import Foundation
import Testing
import MixDSP
@testable import MixEngine

/// Plugin-Verwaltung: Info.plist, VST3, Einstellungen, Absturz-Markierung, eigene Ordner, Installation, auval, Isolation.
/// Alles in temporären Ordnern – nie in ~/Library/Audio oder /Library.

private func tempDir(_ name: String = #function) throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("minos-plugins-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func writePlist(_ obj: Any, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0).write(to: url)
}

/// Bundle mit AudioComponents; `executable`: Symlink auf eine echte Binärdatei
private func fakeComponent(_ dir: URL, _ name: String, components: [[String: Any]], version: String = "1.0.0",
                           executable: String? = nil) throws -> URL {
    let b = dir.appendingPathComponent("\(name).component")
    var info: [String: Any] = ["CFBundleIdentifier": "org.minos741.test.\(name.lowercased())", "CFBundlePackageType": "BNDL",
                               "CFBundleShortVersionString": version, "AudioComponents": components]
    if let executable {
        let exe = URL(fileURLWithPath: executable).lastPathComponent
        info["CFBundleExecutable"] = exe
        try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: b.appendingPathComponent("Contents/MacOS/\(exe)").path,
                                                   withDestinationPath: executable)
    }
    try writePlist(info, to: b.appendingPathComponent("Contents/Info.plist"))
    return b
}

private let mrev = "aufx:mrev:appl"

@Test func componentInfoPlistIsParsed() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = try fakeComponent(dir, "Fake", components: [
        ["type": "aufx", "subtype": "fk01", "manufacturer": "Mnos", "name": "MINOS: Fake One", "version": 65792, "factoryFunction": "FakeFactory"],
        ["type": "aumf", "subtype": "fk02", "manufacturer": "Mnos", "name": "MINOS: Fake Two", "version": "0x10600", "factoryFunction": "F2"],
        ["type": "aumu", "subtype": "fk03", "manufacturer": "Mnos", "name": "Synth", "version": 1, "factoryFunction": "F3"],
        ["type": "aufx", "subtype": "bad", "manufacturer": "Mnos", "factoryFunction": "X"],          // Subtyp nicht 4 Zeichen
        ["type": "aufx", "subtype": "fk05", "manufacturer": "Mnos", "name": "no factory"],         // keine Fabrik
    ], version: "2.3.4")
    let c = PluginBundle.components(b)
    #expect(c.count == 3)
    #expect(c[0].id == "aufx:fk01:Mnos" && c[0].name == "MINOS: Fake One" && c[0].version == 65792 && c[0].factoryFunction == "FakeFactory")
    #expect(PluginHost.versionString(c[0].version) == "1.1.0")
    #expect(c[1].version == 0x10600 && c[1].isEffect)
    #expect(!c[2].isEffect)
    #expect(PluginBundle.version(b) == "2.3.4")
    #expect(PluginBundle.components(dir.appendingPathComponent("missing.component")).isEmpty)
}

@Test func vst3BundlesAreListedButNotLoadable() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let nested = dir.appendingPathComponent("Vendor/Sub")
    let v = nested.appendingPathComponent("Wobble.vst3")
    try writePlist(["CFBundleName": "Wobble", "CFBundleShortVersionString": "1.2"], to: v.appendingPathComponent("Contents/Info.plist"))
    try Data(#"{ "Name": "Wobble FX", "Version": "1.2.0", "Factory Info": { "Vendor": "Someone" } }"#.utf8)
        .write(to: v.appendingPathComponent("Contents/Resources/moduleinfo.json").creatingParent())
    // in einem Bundle nicht weitersuchen
    try writePlist([:], to: dir.appendingPathComponent("Host.app/Contents/Inner.vst3/Contents/Info.plist"))
    let found = PluginBundle.scan(dir)
    #expect(found.vst3.map(\.path) == [v.path])
    #expect(found.components.isEmpty)
    let info = PluginBundle.vst3Info(v)
    #expect(info.name == "Wobble FX" && info.vendor == "Someone" && info.version == "1.2")

    let cat = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    cat.update { $0.folders = [dir.path] }
    let e = try #require(cat.entries(refresh: true).first { $0.format == .vst3 })
    #expect(e.info == nil && e.name == "Wobble FX" && e.source == .folder && !e.canValidate)
    #expect(!cat.menuList().contains { $0.name == "Wobble FX" })
}

@Test func enableDisablePersists() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(a.menuList().contains { $0.id == mrev })
    a.setEnabled(mrev, false)
    a.setIsolation(mrev, true)
    a.update { $0.isolateThirdParty = false }
    #expect(!a.menuList().contains { $0.id == mrev })
    #expect(a.unusableReason(mrev) != nil)

    let b = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(!b.isEnabled(mrev))
    #expect(!b.menuList().contains { $0.id == mrev })
    #expect(b.entries().contains { $0.id == mrev })      // in der Liste der Einstellungen bleibt es
    #expect(b.settings.isolation[mrev] == true && !b.settings.isolateThirdParty)
    #expect(b.isolated(mrev))                              // eigene Einstellung schlägt den Standard
    b.setIsolation(mrev, nil)
    #expect(!b.isolated(mrev))                             // Apple: Standard = im Prozess
    b.setEnabled(mrev, true)
    #expect(PluginCatalog(directory: dir, folders: [], vst3Folders: []).menuList().contains { $0.id == mrev })

    // nur lesen (Selbsttest): nichts geschrieben
    let ro = PluginCatalog(directory: dir, readOnly: true, folders: [], vst3Folders: [])
    ro.setEnabled(mrev, false)
    #expect(PluginCatalog(directory: dir, folders: [], vst3Folders: []).isEnabled(mrev))
}

@Test func crashMarkerBlocksOnNextLaunch() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let marker = dir.appendingPathComponent("plugin-opening.json")
    // sauber geöffnet: keine Markierung, nichts blockiert
    let a = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    a.beginOpen(key: mrev, name: "AUMatrixReverb")
    #expect(FileManager.default.fileExists(atPath: marker.path))
    a.endOpen()
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(PluginCatalog(directory: dir, folders: [], vst3Folders: []).crashedLastRun == nil)

    // "Absturz": Markierung bleibt stehen → beim nächsten Start blockiert
    a.beginOpen(key: mrev, name: "AUMatrixReverb")
    let ro = PluginCatalog(directory: dir, readOnly: true, folders: [], vst3Folders: [])
    #expect(ro.crashedLastRun == nil)                      // Selbsttest lässt die Markierung liegen
    let b = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(b.crashedLastRun?.key == mrev && b.crashedLastRun?.name == "AUMatrixReverb")
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(b.blockReason(mrev) != nil)
    #expect(!b.menuList().contains { $0.id == mrev })
    #expect(b.unusableReason(mrev)?.isEmpty == false)

    let c = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(c.crashedLastRun == nil && c.blockReason(mrev) != nil)   // bleibt blockiert bis zum Zurücksetzen
    c.unblock(mrev)
    #expect(PluginCatalog(directory: dir, folders: [], vst3Folders: []).menuList().contains { $0.id == mrev })
}

/// eigener Ordner: Bundle laden und im Prozess registrieren (Fabrik aus Apples CoreAudio.component per Symlink),
/// dann wie ein installiertes öffnen und offline durch den Kern rechnen
@Test func ownFolderComponentIsRegisteredAndRenders() throws {
    let exe = "/System/Library/Components/CoreAudio.component/Contents/MacOS/CoreAudio"
    try #require(FileManager.default.fileExists(atPath: exe))
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let folder = dir.appendingPathComponent("my plugins")
    _ = try fakeComponent(folder.appendingPathComponent("eq"), "OwnEQ", components: [
        ["type": "aufx", "subtype": "Mtst", "manufacturer": "Mnos", "name": "MINOS Test: Own EQ", "version": 65536,
         "factoryFunction": "AUNBandEQFactory"],
    ], executable: exe)
    let broken = try fakeComponent(folder, "Broken", components: [
        ["type": "aufx", "subtype": "Mbrk", "manufacturer": "Mnos", "name": "MINOS Test: Broken", "version": 1, "factoryFunction": "Nope"],
    ])
    let cat = PluginCatalog(directory: dir.appendingPathComponent("store"), folders: [], vst3Folders: [])
    cat.update { $0.folders = [folder.path] }
    let list = cat.entries(refresh: true)
    let e = try #require(list.first { $0.id == "aufx:Mtst:Mnos" })
    #expect(e.source == .folder && e.format == .auv2 && e.name == "Own EQ" && e.manufacturer == "MINOS Test" && e.version == "1.0.0")
    #expect(!e.canIsolate && !cat.isolated(e.id))
    let bad = try #require(list.first { $0.id == "bundle:" + broken.path })
    #expect(bad.info == nil && bad.problem != nil)
    // live-Regel: nur im Prozess ladbar -> erst mit „Plugins im Prozess“
    #expect(!cat.menuList().contains { $0.id == e.id } && cat.inProcessReason(e.id) != nil)
    cat.update { $0.allowInProcess = true }
    #expect(cat.menuList().contains { $0.id == e.id } && cat.inProcessReason(e.id) == nil)
    // zweites Einlesen registriert nicht doppelt
    #expect(cat.entries(refresh: true).filter { $0.id == e.id }.count == 1)

    // Ordner entfernt: bleibt im Prozess registriert, steht aber nicht mehr in der Liste
    let other = PluginCatalog(directory: dir.appendingPathComponent("store2"), folders: [], vst3Folders: [])
    #expect(!other.entries(refresh: true).contains { $0.id == e.id })

    let inst = try PluginInstance(try #require(e.info), sampleRate: 44100)
    #expect(!inst.outOfProcess)
    let rms = renderThroughCore(inst)
    #expect(rms > 1e-3)
}

/// Rauschen durch den Kern (FX 1, Deck A, D/W 1), liefert den mittleren RMS nach 0,5 s
private func renderThroughCore(_ inst: PluginInstance, fs: Double = 44100) -> Float {
    let e = mdsp_create(fs)!
    defer { mdsp_destroy(e) }
    let frames = Int(fs * 2)
    let l = UnsafeMutablePointer<Float>.allocate(capacity: frames), r = UnsafeMutablePointer<Float>.allocate(capacity: frames)
    defer { l.deallocate(); r.deallocate() }
    var seed: UInt32 = 99
    for i in 0..<frames { seed = seed &* 1664525 &+ 1013904223; let v = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6; l[i] = v; r[i] = v }
    mdsp_set_track(e, 0, l, r, Int64(frames), fs, 0)
    mdsp_set_param(e, 0, MD_FX1_ASSIGN, 1)
    setSlotPlugin(e, 0, 0, inst.ptr)
    mdsp_set_fx(e, 0, MDFX_DRYWET, 1); mdsp_set_fx_slot(e, 0, 0, true, 1)
    mdsp_set_param(e, 0, MD_PLAYING, 1)
    var outL = [Float](repeating: 0, count: 512), outR = [Float](repeating: 0, count: 512)
    var acc: Float = 0, n = 0
    var finite = true
    for b in 0..<Int(1.5 * fs / 512) {
        outL.withUnsafeMutableBufferPointer { lp in
            outR.withUnsafeMutableBufferPointer { rp in
                var ch: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                ch.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, 512) }
            }
        }
        finite = finite && outL.allSatisfy(\.isFinite)
        if b > Int(fs / 512) { acc += (outL.reduce(0) { $0 + $1 * $1 } / 512).squareRoot(); n += 1 }
    }
    setSlotPlugin(e, 0, 0, nil)
    return finite ? acc / Float(max(n, 1)) : -1
}

/// isoliert (außerhalb des Prozesses) geladen: AUMatrixReverb klingt offline durch den Kern; Messung gegen im Prozess
@Test func outOfProcessPluginRendersAndIsMeasured() throws {
    let info = try #require(PluginHost.installed().first { $0.id == mrev })
    let iso = try PluginInstance(info, sampleRate: 48000, outOfProcess: true, timeout: 60)   // xpc-start unter voller cpu-last > 10 s
    #expect(iso.outOfProcess)
    #expect(iso.parameters.count >= 3)
    iso.setKnob(0, 0.3)
    #expect(abs((iso.knob(0) ?? -1) - 0.3) < 0.01)
    #expect(iso.state != nil)
    let rms = renderThroughCore(iso, fs: 48000)
    print(String(format: "[iso] AUMatrixReverb isoliert durch den Kern: rms %.4f", rms))
    #expect(rms > 1e-3)

    // Kosten je 512er-Block am Audio-Thread (Wandzeit von AudioUnitRender) und gemeldete Latenz, beide Wege
    func bench(_ p: PluginInstance) -> (lat: Double, mean: Double, p99: Double, max: Double) {
        let n = 512, blocks = 1500
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        var t: [Double] = []
        var seed: UInt32 = 5
        for b in 0..<(blocks + 50) {
            for i in 0..<n { seed = seed &* 1664525 &+ 1013904223; l[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.5; r[i] = l[i] }
            let t0 = DispatchTime.now().uptimeNanoseconds
            p.process(l, r, n)
            let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if b >= 50 { t.append(dt) }
        }
        t.sort()
        return (p.latency, t.reduce(0, +) / Double(t.count), t[Int(Double(t.count) * 0.99)], t.last ?? 0)
    }
    let inproc = try PluginInstance(info, sampleRate: 48000)
    let a = bench(inproc), b = bench(iso)
    let budget = 512.0 / 48000 * 1000
    print(String(format: "[iso] 512 frames @ 48 kHz (budget %.2f ms) · im prozess: latenz %.1f ms, mittel %.3f ms (%.1f %%), p99 %.3f ms, max %.3f ms · isoliert: latenz %.1f ms, mittel %.3f ms (%.1f %%), p99 %.3f ms, max %.3f ms",
                 budget, a.lat * 1000, a.mean, a.mean / budget * 100, a.p99, a.max, b.lat * 1000, b.mean, b.mean / budget * 100, b.p99, b.max))
    #expect(b.mean < budget)
}

@Test func installerCopiesAsksAndClearsQuarantine() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("download")
    let one = try fakeComponent(src, "One", components: [], version: "1.0")
    try Data("x".utf8).write(to: one.appendingPathComponent("Contents/Resources/file.txt").creatingParent())
    let vst = src.appendingPathComponent("deep/Two.vst3")
    try writePlist(["CFBundleName": "Two"], to: vst.appendingPathComponent("Contents/Info.plist"))
    // zip mit einem weiteren Bundle
    let zipSrc = try fakeComponent(dir.appendingPathComponent("zipsrc"), "Three", components: [], version: "3.0")
    let zip = dir.appendingPathComponent("three.zip")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    p.arguments = ["-c", "-k", "--keepParent", zipSrc.path, zip.path]
    try p.run(); p.waitUntilExit()
    #expect(p.terminationStatus == 0)

    let scratch = dir.appendingPathComponent("scratch")
    let got = try PluginInstaller.collect([src, zip], scratch: scratch)
    #expect(got.components.map(\.lastPathComponent).sorted() == ["One.component", "Three.component"])
    #expect(got.vst3.map(\.lastPathComponent) == ["Two.vst3"])

    // Quarantäne: gesetzt → erkannt → nach dem Kopieren im Ziel entfernt
    let q = "0081;00000000;Test;"
    #expect(setxattr(one.appendingPathComponent("Contents/Resources/file.txt").path, "com.apple.quarantine", q, q.utf8.count, 0, 0) == 0)
    #expect(PluginInstaller.isQuarantined(one))

    let dest = dir.appendingPathComponent("Components")
    #expect(PluginInstaller.conflict(one, in: dest) == nil)
    let target = try PluginInstaller.install(one, into: dest)
    #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/Info.plist").path))
    #expect(PluginInstaller.isQuarantined(target))
    PluginInstaller.clearQuarantine(target)
    #expect(!PluginInstaller.isQuarantined(target))

    // gleiche Datei nochmal: gleiche Version; neuere: andere Version → Rückfrage
    #expect(PluginInstaller.conflict(one, in: dest)?.sameVersion == true)
    let newer = try fakeComponent(dir.appendingPathComponent("v2"), "One", components: [], version: "2.0")
    let c = try #require(PluginInstaller.conflict(newer, in: dest))
    #expect(!c.sameVersion && c.oldVersion == "1.0" && c.newVersion == "2.0")
    try PluginInstaller.install(newer, into: dest)
    #expect(PluginBundle.version(target) == "2.0")
    let left = try FileManager.default.contentsOfDirectory(atPath: dest.path)
    #expect(left == ["One.component"])   // keine Reste vom Tauschen
}

@Test func auvalPassesForMatrixReverb() async throws {
    let info = try #require(PluginHost.installed().first { $0.id == mrev })
    let v = PluginValidator()
    let r = await v.run(info)
    print("[auval] \(r.passed ? "bestanden" : "FEHLER")\n\(r.log)")
    #expect(r.passed)
    #expect(r.log.contains("AU VALIDATION SUCCEEDED"))
    v.cancel()
    let c = await v.run(info)
    #expect(!c.passed)
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

/// live-Regel: ohne „Plugins im Prozess“ laufen Fremd-Audio-Units isoliert (auch gegen die Einstellung je Plugin),
/// Apple im Prozess; mit der Einstellung gelten Standard und Einstellung je Plugin wie zuvor
@Test func liveRuleIsolatesThirdPartyUnlessInProcessAllowed() {
    let s0 = PluginSettings()
    #expect(!s0.allowInProcess)
    let third = PluginEntry(id: "aufx:Tst1:Mnos", name: "T", manufacturer: "M", version: "1", format: .auv2, source: .user, path: nil,
                            info: PluginInfo(id: "aufx:Tst1:Mnos", name: "T", manufacturer: "M", type: 0x61756678, subtype: 1, manu: 2),
                            problem: nil)
    let apple = PluginEntry(id: mrev, name: "MatrixReverb", manufacturer: "Apple", version: "1", format: .auv2, source: .system, path: nil,
                            info: PluginInfo(id: mrev, name: "MatrixReverb", manufacturer: "Apple", type: 0x61756678, subtype: 0x6d726576,
                                             manu: 0x6170706c), problem: nil)
    var vinfo = PluginInfo.vst3(classID: String(repeating: "A", count: 32), name: "V", vendor: "M", version: "1", path: "/x.vst3")
    vinfo.format = .vst3
    let vst3 = PluginEntry(id: vinfo.id, name: "V", manufacturer: "M", version: "1", format: .vst3, source: .user, path: "/x.vst3",
                           info: vinfo, problem: nil)
    var s = s0
    s.isolation[third.id] = false   // „im Prozess“ je Plugin zählt live nicht
    #expect(PluginCatalog.isolated(third, s) && !PluginCatalog.isolated(apple, s))
    #expect(PluginCatalog.inProcessOnly(vst3, s) && !PluginCatalog.inProcessOnly(third, s) && !PluginCatalog.inProcessOnly(apple, s))
    s.allowInProcess = true
    #expect(!PluginCatalog.isolated(third, s) && !PluginCatalog.inProcessOnly(vst3, s))
    s.isolation[third.id] = nil
    #expect(PluginCatalog.isolated(third, s))   // Standard: Drittanbieter isoliert
}

/// Abstürze isolierter Plugins: gezählt und gespeichert, beim dritten gesperrt; Block aufheben setzt den Zähler zurück
@Test func isolatedCrashesBlockAfterLimit() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(a.recordCrash("aufx:Tst1:Mnos") == 1)
    #expect(a.recordCrash("aufx:Tst1:Mnos") == 2)
    #expect(a.unusableReason("aufx:Tst1:Mnos") == nil)
    let b = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(b.settings.crashes["aufx:Tst1:Mnos"] == 2)
    #expect(b.recordCrash("aufx:Tst1:Mnos") == PluginCatalog.crashLimit)
    #expect(b.unusableReason("aufx:Tst1:Mnos") != nil)
    b.unblock("aufx:Tst1:Mnos")
    #expect(b.settings.crashes["aufx:Tst1:Mnos"] == nil && b.unusableReason("aufx:Tst1:Mnos") == nil)
}

/// Mach-O-Kopf: Architekturen ohne Laden (fat und dünn); nur-Intel-Plugins: AU nur isoliert, VST3 gesperrt, beide in der Auswahl
@Test func architectureFromMachOHeader() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    func bundle(_ name: String, _ bytes: [UInt8]) throws -> URL {
        let b = dir.appendingPathComponent("\(name).component")
        try writePlist(["CFBundleExecutable": name], to: b.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: b.appendingPathComponent("Contents/MacOS/\(name)"))
        return b
    }
    let fat = try bundle("Fat", [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 0, 0, 0, 7, 0, 0, 0, 3, 0, 0, 0x10, 0, 0, 0, 0x10, 0, 0, 0, 0, 12,
                                 0x01, 0, 0, 0x07])
    #expect(PluginBundle.architectures(fat) == ["i386", "x86_64"])
    let thin = try bundle("Thin", [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0, 0, 0x01])
    #expect(PluginBundle.architectures(thin) == ["arm64"])
    #expect(PluginBundle.architectures(dir.appendingPathComponent("none.component")).isEmpty)
    // echte Binärdatei dieses Tests
    let exe = URL(fileURLWithPath: CommandLine.arguments[0])
    let host = try bundle("Host", [UInt8](try Data(contentsOf: exe).prefix(4096)))
    #expect(PluginBundle.architectures(host).contains(PluginBundle.hostArch))

    let intel = ["i386", "x86_64"]
    let other = PluginBundle.hostArch == "arm64" ? intel : ["arm64"]
    let au = PluginEntry(id: "aufx:Int1:Mnos", name: "I", manufacturer: "M", version: "1", format: .auv2, source: .user, path: "/i.component",
                         info: PluginInfo(id: "aufx:Int1:Mnos", name: "I", manufacturer: "M", type: 0x61756678, subtype: 1, manu: 2),
                         problem: nil, architectures: other)
    var s = PluginSettings()
    s.allowInProcess = true
    s.isolation[au.id] = false
    #expect(au.foreignArch && PluginCatalog.isolated(au, s))   // im Prozess eingestellt: trotzdem isoliert
    let native = PluginEntry(id: au.id, name: "I", manufacturer: "M", version: "1", format: .auv2, source: .user, path: "/i.component",
                             info: au.info, problem: nil, architectures: [PluginBundle.hostArch])
    #expect(!native.foreignArch && !PluginCatalog.isolated(native, s))
}

/// plugins.json mit auval-Ergebnis wird wieder gelesen (Datum ISO 8601), Einstellungen bleiben über den Neustart
@Test func settingsWithValidationSurviveRestart() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    a.update { $0.disabled.insert("aufx:x:y"); $0.allowInProcess = true; $0.validation["aufx:x:y@1"] = PluginValidation(passed: true, log: "ok") }
    let b = PluginCatalog(directory: dir, folders: [], vst3Folders: [])
    #expect(b.settings.disabled.contains("aufx:x:y") && b.settings.allowInProcess)
    #expect(b.settings.validation["aufx:x:y@1"]?.passed == true)
}

/// Auswahl: VST3 ohne „Plugins im Prozess“ gesperrt mit Grund (statt weggelassen), mit Freigabe ladbar
@Test func pickerShowsLockedVST3() throws {
    let dir = try tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let vdir = dir.appendingPathComponent("VST3")
    let b = vdir.appendingPathComponent("Fake.vst3")
    try FileManager.default.createDirectory(at: b.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    let mi = #"{"Name":"Fake","Version":"1.0","Factory Info":{"Vendor":"Mnos"},"Classes":[{"CID":"0123456789ABCDEF0123456789ABCDEF","Category":"Audio Module Class","Sub Categories":["Fx"],"Name":"Fake FX"}]}"#
    try Data(mi.utf8).write(to: b.appendingPathComponent("Contents/Resources/moduleinfo.json"))
    let cat = PluginCatalog(directory: dir, folders: [], vst3Folders: [vdir])
    let c = try #require(cat.pickerList().first { $0.info.name == "Fake FX" })
    #expect(c.lock != nil && c.fixInSettings && !cat.menuList().contains { $0.id == c.id })
    #expect(cat.pickerList().contains { $0.info.id == mrev && $0.lock == nil })
    cat.update { $0.allowInProcess = true }
    #expect(cat.pickerList().first { $0.info.name == "Fake FX" }?.lock == nil)
}
