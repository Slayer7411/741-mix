import Foundation
import Observation
import MixCore

/// EXPLORER-Suche über Spotlight: Ordner und Audiodateien mit dem Text im Namen, auf allen lokalen Laufwerken
/// (auch USB-Sticks). Ergebnis: Ordner für den Baum (`ExplorerHits`). Nicht indizierte Laufwerke liefern nichts
@MainActor @Observable
final class ExplorerSearch {
    private(set) var folders: [String] = []
    private(set) var running = false
    @ObservationIgnored private var query: NSMetadataQuery?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var pending: DispatchWorkItem?
    /// zählt je Suche (verspätete Ergebnisse verwerfen)
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var spotlight: [(path: String, folder: Bool)]?
    @ObservationIgnored private var walked: [(path: String, folder: Bool)]?

    /// Spotlight-Index des Laufwerks an
    nonisolated static func indexed(_ volume: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        p.arguments = ["-s", volume.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return s.contains("Indexing enabled")
    }

    /// nach kurzer Tipp-Pause suchen; leer = aus
    func run(_ text: String) {
        pending?.cancel()
        generation += 1
        spotlight = nil
        walked = nil
        stop()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { folders = []; return }
        running = true
        let w = DispatchWorkItem { [weak self] in self?.start(q) }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func start(_ text: String) {
        // Laufwerke ohne Index direkt durchgehen (parallel zu Spotlight)
        walked = nil
        let gen = generation
        let volumes = ExplorerTree.mountedVolumes()
        DispatchQueue.global(qos: .utility).async {
            let hits = volumes.filter { !Self.indexed($0) }.flatMap { ExplorerHits.walk($0, matching: text) }
            DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in
                guard let self, gen == self.generation else { return }
                self.walked = hits
                self.publish()
            } }
        }
        let m = NSMetadataQuery()
        m.searchScopes = [NSMetadataQueryLocalComputerScope]
        m.predicate = NSPredicate(format: "%K LIKE[cd] %@ AND (%K == 'public.folder' OR %K == 'public.audio')",
                                  NSMetadataItemFSNameKey, "*\(text)*", NSMetadataItemContentTypeKey, NSMetadataItemContentTypeTreeKey)
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: m, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in self?.finish(m) }
        }
        query = m
        m.start()
    }

    private func finish(_ m: NSMetadataQuery) {
        guard m === query else { return }
        m.disableUpdates()
        var hits: [(path: String, folder: Bool)] = []
        for case let item as NSMetadataItem in m.results {
            guard let p = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            hits.append((p, (item.value(forAttribute: NSMetadataItemContentTypeKey) as? String) == "public.folder"))
        }
        spotlight = hits
        stop()
        publish()
    }

    /// Ergebnis, sobald Spotlight und das Durchgehen fertig sind
    private func publish() {
        guard let spotlight, let walked else { return }
        folders = ExplorerHits.folders(spotlight + walked, home: FileManager.default.homeDirectoryForCurrentUser.path)
        running = false
    }

    private func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
