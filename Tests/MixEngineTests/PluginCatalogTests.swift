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
    #expect(cat.menuList().contains { $0.id == e.id })
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
    _ = mdsp_set_fx_plugin(e, 0, 0, inst.ptr)
    mdsp_set_fx(e, 0, MDFX_DRYWET, 1); mdsp_set_fx(e, 0, MDFX_PLUGIN_ON, 1)
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
    _ = mdsp_set_fx_plugin(e, 0, 0, nil)
    return finite ? acc / Float(max(n, 1)) : -1
}

/// isoliert (außerhalb des Prozesses) geladen: AUMatrixReverb klingt offline durch den Kern; Messung gegen im Prozess
@Test func outOfProcessPluginRendersAndIsMeasured() throws {
    let info = try #require(PluginHost.installed().first { $0.id == mrev })
    let iso = try PluginInstance(info, sampleRate: 48000, outOfProcess: true)
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
