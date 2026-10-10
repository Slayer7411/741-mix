import Foundation

/// Ressourcen finden: im App-Paket (Contents/Resources/Resources/…) oder beim Direktstart aus dem SwiftPM-Bundle.
/// Bundle.module bricht hart ab, wenn das Bundle fehlt – deshalb zuerst im App-Paket suchen.
enum AppResources {
    static func url(_ name: String, _ ext: String?) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Resources") { return u }
        if Bundle.main.bundleURL.pathExtension == "app" { return nil }
        return Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }

    /// Einstellungen aus der Zeit vor dem App-Paket übernehmen (Domain „741mix“ → Bundle-ID), einmalig
    static func migrateDefaults() {
        guard let id = Bundle.main.bundleIdentifier, id != "741mix" else { return }
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migrated.from.741mix"), let old = UserDefaults(suiteName: "741mix") else { return }
        for (k, v) in old.dictionaryRepresentation() where !k.hasPrefix("NS") && !k.hasPrefix("Apple") && d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migrated.from.741mix")
    }
}
