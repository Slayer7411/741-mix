import Foundation

/// Musik-Ordner im Dateisystem: Verzeichnisse lesen, Dateien den Collection-Tracks zuordnen.
/// Reine Funktionen ohne Zustand – der Zwischenspeicher liegt im MusicFolderStore der App.
public enum MusicFolder {
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "aiff", "aif", "wav", "flac", "ogg", "opus"]

    /// eine Audiodatei im Ordner: Pfad, Vergleichsschlüssel, Track für Dateien außerhalb der Collection
    public struct File: Sendable, Hashable {
        public var path: String
        public var match: String
        public var loose: Track
    }

    public struct Listing: Sendable {
        /// Unterordner (absolute Pfade), sortiert wie im Finder
        public var folders: [String] = []
        public var files: [File] = []
        public init() {}
    }

    /// Vergleichsform eines Pfads: NFC und klein (APFS ist normalisierungs- und meist groß/klein-unempfindlich)
    public static func match(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Pfad-Index der Collection (Vergleichsform → Track-Schlüssel), einmal pro geladener Collection
    public static func pathIndex(_ tracks: [Track]) -> [String: String] {
        var d = [String: String](minimumCapacity: tracks.count)
        for t in tracks where !t.path.isEmpty {
            let m = match(t.path)
            if d[m] == nil { d[m] = t.key }
        }
        return d
    }

    /// Ordner lesen: Unterordner und Audiodateien (versteckte und Pakete übersprungen);
    /// `recursive` = alle Audiodateien darunter, Unterordner dann nur die erste Ebene
    public static func list(_ dir: String, recursive: Bool = false) -> Listing {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        let (volume, mount) = volumeInfo(dir)
        var out = Listing()
        // Pfade mit dem angefragten Präfix zurückgeben (z. B. /var statt /private/var), sonst passt der Index nicht
        let resolved = realpath(dir, nil).map { p in defer { free(p) }; return String(cString: p) } ?? dir
        let base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        func keep(_ u: URL) -> String {
            let p = u.path
            if p.hasPrefix(base + "/") { return p }
            return p.hasPrefix(resolved + "/") ? base + p.dropFirst(resolved.count) : p
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
        var files: [URL] = []
        for u in items {
            let v = try? u.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true, v?.isPackage != true { out.folders.append(keep(u)) }
            else if audioExtensions.contains(u.pathExtension.lowercased()) { files.append(u) }
        }
        if recursive {
            files = []
            let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let u = e?.nextObject() as? URL {
                if audioExtensions.contains(u.pathExtension.lowercased()) { files.append(u) }
            }
        }
        out.folders.sort { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        out.files = files.map { file(keep($0), volume: volume, mount: mount) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return out
    }

    public static func file(_ path: String, volume: String, mount: String) -> File {
        File(path: path, match: match(path), loose: looseTrack(path, volume: volume, mount: mount))
    }

    /// Track für eine Datei außerhalb der Collection: Schlüssel wie in der NML (VOLUME + DIR + FILE),
    /// Titel aus dem Dateinamen („Artist - Title“ wird geteilt), ohne Grid
    public static func looseTrack(_ path: String, volume: String, mount: String) -> Track {
        var t = Track(key: nmlKey(path, volume: volume, mount: mount), path: path)
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let r = name.range(of: " - ") {
            t.artist = String(name[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            t.title = String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else {
            t.title = name
        }
        t.loose = true
        t.fileMissing = false
        t.buildSearchText()
        return t
    }

    /// "/Users/x/a.mp3" auf "Macintosh HD" → "Macintosh HD/:Users/:x/:a.mp3"; auf /Volumes/Y relativ zum Volume
    public static func nmlKey(_ path: String, volume: String, mount: String) -> String {
        var rel = path
        if mount != "/", rel.hasPrefix(mount) { rel = String(rel.dropFirst(mount.count)) }
        let comps = rel.split(separator: "/").map(String.init)
        guard let file = comps.last else { return volume + "/:" }
        return volume + "/:" + comps.dropLast().map { $0 + "/:" }.joined() + file
    }

    /// Volume-Name und Einhängepunkt eines Pfads (einmal je Ordner)
    public static func volumeInfo(_ path: String) -> (name: String, mount: String) {
        let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey, .volumeURLKey])
        let mount = v?.volume?.path ?? "/"
        return (v?.volumeName ?? "Macintosh HD", mount.hasSuffix("/") && mount != "/" ? String(mount.dropLast()) : mount)
    }

    /// Standard-Musikordner: tiefster Ordner, der noch `share` der vorhandenen Dateien enthält
    /// (einzelne Ausreißer in Downloads/Desktop ziehen den Ordner so nicht bis ins Benutzerverzeichnis hoch)
    public static func defaultRoot(paths: [String], share: Double = 0.9) -> String? {
        guard !paths.isEmpty else { return nil }
        let dirs = paths.map { ($0 as NSString).deletingLastPathComponent.split(separator: "/").map(String.init) }
        let need = Int((Double(dirs.count) * share).rounded(.up))
        var prefix: [String] = []
        var current = dirs
        while true {
            var counts: [String: Int] = [:]
            for d in current where d.count > prefix.count { counts[d[prefix.count], default: 0] += 1 }
            guard let best = counts.max(by: { $0.value < $1.value }), best.value >= need else { break }
            prefix.append(best.key)
            current = current.filter { $0.count >= prefix.count && $0[prefix.count - 1] == best.key }
        }
        return "/" + prefix.joined(separator: "/")
    }
}
