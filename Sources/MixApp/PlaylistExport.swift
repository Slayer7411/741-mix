import AppKit
import Foundation
import MixCore

/// Playlist-Export wie Traktor: NML (Traktor-Import), M3U, oder Ordner mit Audiodateien + NML + M3U.
@MainActor
enum PlaylistExport {
    enum Format { case nml, m3u, folder }

    static func run(_ format: Format, name: String, tracks: [Track], store: LibraryStore) {
        guard !tracks.isEmpty else { store.status = "export: liste ist leer"; return }
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        switch format {
        case .nml, .m3u:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = safe + (format == .nml ? ".nml" : ".m3u8")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let text = format == .nml ? nml(name: name, tracks: tracks, store: store) : m3u(tracks, relativeTo: nil)
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                store.status = "exportiert: \(tracks.count) tracks -> \(url.lastPathComponent)"
            } catch { store.status = "export fehlgeschlagen: \(error.localizedDescription)" }
        case .folder:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Hierhin exportieren"
            guard panel.runModal() == .OK, let base = panel.url else { return }
            let dir = base.appendingPathComponent(safe)
            let index = store.entryIndex
            store.status = "export läuft: 0/\(tracks.count)"
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                var copied = 0, failed = 0
                for (i, t) in tracks.enumerated() {
                    let dst = dir.appendingPathComponent(String(format: "%03d ", i + 1) + t.fileName)
                    do {
                        if !fm.fileExists(atPath: dst.path) { try fm.copyItem(at: URL(fileURLWithPath: t.path), to: dst) }
                        copied += 1
                    } catch { failed += 1 }
                    let n = i + 1
                    if n % 5 == 0 { await MainActor.run { store.status = "export läuft: \(n)/\(tracks.count)" } }
                }
                let entries = tracks.map { entry($0) }
                let nmlText = TraktorPlaylistWriter.nml(name: name, entries: entries, index: index)
                try? nmlText.write(to: dir.appendingPathComponent(safe + ".nml"), atomically: true, encoding: .utf8)
                let m3uText = await m3u(tracks, relativeTo: dir)
                try? m3uText.write(to: dir.appendingPathComponent(safe + ".m3u8"), atomically: true, encoding: .utf8)
                await MainActor.run {
                    store.status = "exportiert: \(copied) dateien -> \(dir.path)" + (failed > 0 ? " · \(failed) fehlgeschlagen" : "")
                }
            }
        }
    }

    nonisolated static func entry(_ t: Track) -> HistoryEntry {
        HistoryEntry(key: t.key, title: t.title, artist: t.artist, bpm: t.bpm, keyText: t.openKey, deck: 0, start: Date(), duration: t.duration)
    }

    static func nml(name: String, tracks: [Track], store: LibraryStore) -> String {
        TraktorPlaylistWriter.nml(name: name, entries: tracks.map(entry), index: store.entryIndex)
    }

    /// M3U8; mit `relativeTo` zeigen die Pfade auf die kopierten Dateien im Exportordner
    static func m3u(_ tracks: [Track], relativeTo dir: URL?) -> String {
        var out = "#EXTM3U\n"
        for (i, t) in tracks.enumerated() {
            out += "#EXTINF:\(Int(t.duration)),\(t.artist) - \(t.title)\n"
            out += (dir != nil ? String(format: "%03d ", i + 1) + t.fileName : t.path) + "\n"
        }
        return out
    }
}
