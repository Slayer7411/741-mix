import Foundation

/// EXPLORER-Suche: Spotlight-Treffer (Ordner, Audiodateien) -> Ordner für den Baum. Ordner mit dem Namen zuerst,
/// dann die Ordner der gefundenen Dateien; ohne System-, Programm- und versteckte Pfade (Google Drive unter
/// ~/Library/CloudStorage bleibt drin)
public enum ExplorerHits {
    public static let limit = 150

    /// Laufwerke ohne Spotlight-Index (USB-Sticks): Namen direkt durchgehen, höchstens `maxEntries` Einträge je Laufwerk
    public static let maxEntries = 50_000
    public static let audioExtensions: Set<String> = ["mp3", "wav", "aif", "aiff", "flac", "m4a", "aac", "ogg", "alac", "mp4"]

    public static func walk(_ root: URL, matching text: String) -> [(path: String, folder: Bool)] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [(path: String, folder: Bool)] = [], n = 0
        for case let u as URL in e {
            n += 1
            if n > maxEntries { break }
            let name = u.lastPathComponent
            guard name.localizedStandardContains(text) else { continue }
            let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if dir || audioExtensions.contains(u.pathExtension.lowercased()) { out.append((u.path, dir)) }
        }
        return out
    }

    public static func folders(_ hits: [(path: String, folder: Bool)], home: String) -> [String] {
        let hidden = ["/System/", "/Library/", "/Applications/", "/private/", home + "/Library/"]
        let cloud = home + "/Library/CloudStorage/"
        func ok(_ p: String) -> Bool {
            (p.hasPrefix(cloud) || !hidden.contains { p.hasPrefix($0) }) && !p.split(separator: "/").contains { $0.hasPrefix(".") }
        }
        var named: [String] = [], parents: [String] = [], seen: Set<String> = []
        for h in hits where ok(h.path) {
            if h.folder {
                if seen.insert(h.path).inserted { named.append(h.path) }
            } else {
                let dir = (h.path as NSString).deletingLastPathComponent
                if seen.insert(dir).inserted { parents.append(dir) }
            }
        }
        let byName = { (a: String, b: String) in
            (a as NSString).lastPathComponent.localizedStandardCompare((b as NSString).lastPathComponent) == .orderedAscending
        }
        return Array((named.sorted(by: byName) + parents.sorted(by: byName)).prefix(limit))
    }
}
