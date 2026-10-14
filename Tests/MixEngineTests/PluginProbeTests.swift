import AudioToolbox
import Foundation
import Testing
import MixDSP
@testable import MixEngine

/// Probe gegen ein installiertes Plugin (nur mit MIX741_PROBE_PLUGIN=<id>): Liste, FX-Menü, isoliert öffnen, einen Block rechnen.
/// Liest die Einstellungen nur (readOnly), schreibt nichts.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_PROBE_PLUGIN"] != nil))
func probeInstalledPlugin() throws {
    let id = ProcessInfo.processInfo.environment["MIX741_PROBE_PLUGIN"]!
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MINOS-741")
    let cat = PluginCatalog(directory: dir, readOnly: true)
    let entries = cat.entries()
    let e = entries.first { $0.id == id }
    print("[probe] entry: \(e.map { "\($0.name) · \($0.manufacturer) · \($0.version) · \($0.format) · \($0.source) · \($0.path ?? "-")" } ?? "nicht in der Liste")")
    if let e { print("[probe] archs: \(e.architectures) · isolated \(PluginCatalog.isolated(e, cat.settings)) · inProcessOnly \(PluginCatalog.inProcessOnly(e, cat.settings))") }
    print("[probe] menuList enthält: \(cat.menuList().contains { $0.id == id }) · Hinweis: \(cat.archNote(id) ?? "-")")
    print("[probe] validation: \(e.flatMap { cat.validation($0) }.map { "\($0.passed)" } ?? "-")")
    guard let info = e?.info else { return }
    for oop in [true, false] {
        let t0 = Date()
        do {
            let p = try PluginInstance(info, sampleRate: 48000, outOfProcess: oop, timeout: 20)
            let n = 512
            let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
            defer { l.deallocate(); r.deallocate() }
            var peak: Float = 0
            for b in 0..<40 {
                for i in 0..<n { let v: Float = (b == 0 && i == 0) ? 1 : 0; l[i] = v; r[i] = v }
                p.process(l, r, n)
                for i in 0..<n { peak = max(peak, abs(l[i]), abs(r[i])) }
            }
            print(String(format: "[probe] %@: geladen in %.2f s · %d Parameter · Ausgang Spitze %.4f · Fehlblöcke %llu",
                         oop ? "isoliert" : "im Prozess", Date().timeIntervalSince(t0), p.parameters.count, peak, p.renderFailures.blocks))
        } catch {
            print(String(format: "[probe] %@: nicht ladbar nach %.2f s · %@", oop ? "isoliert" : "im Prozess", Date().timeIntervalSince(t0),
                         error.localizedDescription))
        }
    }
}
