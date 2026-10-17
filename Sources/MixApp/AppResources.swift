import Foundation
import MixCore

/// Ressourcen finden: im App-Paket (Contents/Resources/Resources/…) oder beim Direktstart aus dem SwiftPM-Bundle.
/// Bundle.module bricht hart ab, wenn das Bundle fehlt – deshalb zuerst im App-Paket suchen.
enum AppResources {
    static func url(_ name: String, _ ext: String?) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return u }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    /// Datei im Ressourcen-Ordner (`Resources/<rel>`, z. B. `Licenses/LICENSE-VST3SDK.txt`): im App-Paket oder beim
    /// Direktstart aus dem SwiftPM-Bundle. Nil, wenn es sie nicht gibt
    static func file(_ rel: String) -> URL? {
        let fm = FileManager.default
        if let u = Bundle.main.resourceURL?.appendingPathComponent("Resources/\(rel)"), fm.fileExists(atPath: u.path) { return u }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        if let u = Bundle.module.resourceURL?.appendingPathComponent("Resources/\(rel)"), fm.fileExists(atPath: u.path) { return u }
        return nil
    }

    /// Einstellungen und Daten aus alten Namen übernehmen (741mix, 741-mix-App), einmalig
    static func migrateDefaults() {
        let d = E2E.defaults
        if !d.bool(forKey: "migrated.v2") {
            // Ende-zu-Ende: nie die Einstellungen des echten Nutzers übernehmen (Tests/E2E/README.md, Isolation)
            for suite in E2E.isActive ? [] : ["com.github.slayer7411.741mix", "741mix"] where suite != Bundle.main.bundleIdentifier {
                guard let old = UserDefaults(suiteName: suite) else { continue }
                for (k, v) in old.dictionaryRepresentation()
                where !k.hasPrefix("NS") && !k.hasPrefix("Apple") && !k.hasPrefix("migrated") && d.object(forKey: k) == nil {
                    d.set(v, forKey: k)
                }
            }
            d.set(true, forKey: "migrated.v2")
        }
        // Datenordner (History, Preparation) vom alten Namen übernehmen
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("741-mix"), new = base.appendingPathComponent("MINOS-741")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
    }
}
