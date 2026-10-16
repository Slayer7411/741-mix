import Foundation
import Observation
import MixCore

/// → TIDAL: Tracks ohne Datei suchen, Playlist anlegen, Nicht-Gefundene merken. Läuft async (Netz im Akteur
/// TidalClient, nicht auf dem Hauptthread); Fortschritt und Abbrechen in der Statusleiste (Schlüssel „tidal“).
@MainActor @Observable
final class TidalSyncModel {
    static let shared = TidalSyncModel()

    private(set) var running = false
    /// Tracks ohne Treffer aus dem letzten Lauf (Blatt „Nicht gefunden“)
    private(set) var unmatched: [Track] = []
    var showUnmatched = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(tracks: [Track], clientID: String, pattern: String) {
        guard !running, !tracks.isEmpty else { return }
        running = true
        unmatched = []
        task = Task { await run(tracks, clientID: clientID, pattern: pattern) }
    }

    func cancel() { task?.cancel() }

    private func run(_ tracks: [Track], clientID: String, pattern: String) async {
        defer { running = false; task = nil }
        let cancel: @MainActor @Sendable () -> Void = { [weak self] in self?.cancel() }
        let id = clientID.trimmingCharacters(in: .whitespaces)
        do {
            let tokens: TidalTokens
            if let t = TidalKeychain.load() {
                tokens = t
            } else {
                StatusCenter.post(.info, "TIDAL: Anmeldung im Browser …", key: "tidal", cancel: cancel)
                tokens = try await TidalAuth.signIn(clientID: id)
            }
            let client = TidalClient(clientID: id, tokens: tokens)
            var country = Locale.current.region?.identifier ?? "US"
            if let c = try? await client.country() { country = c }

            let n = tracks.count
            var found: [String] = []
            var missed: [Track] = []
            for (i, t) in tracks.enumerated() {
                try Task.checkCancellation()
                StatusCenter.post(.info, "TIDAL: suchen \(i + 1) von \(n)", key: "tidal", progress: Double(i) / Double(n),
                                  progressText: "\(i)/\(n)", cancel: cancel)
                let q = TidalMatch.query(artist: t.artist, title: t.title)
                let cands = q.isEmpty ? [] : try await client.search(q, country: country)
                if let hit = TidalMatch.best(title: t.title, artist: t.artist, duration: t.duration, cands) {
                    found.append(hit.id)
                } else {
                    missed.append(t)
                }
            }

            let name = TidalMatch.playlistName(pattern: pattern)
            if !found.isEmpty {
                StatusCenter.post(.info, "TIDAL: Playlist \(name) anlegen", key: "tidal", cancel: cancel)
                let pid = try await client.createPlaylist(name: name, description: "missing files of the MINOS-741 collection")
                try await client.addTracks(found, to: pid)
            }
            unmatched = missed
            let msg = "TIDAL: \(found.count) von \(n) gefunden" + (found.isEmpty ? "" : " · Playlist \(name)")
            StatusCenter.post(missed.isEmpty ? .ok : .warning, msg,
                              detail: missed.isEmpty ? nil : "\(missed.count) ohne Treffer: Liste im Kopf des Bereichs",
                              key: "tidal")
        } catch {
            if Task.isCancelled || { if case .cancelled? = error as? TidalError { true } else { false } }() {
                StatusCenter.post(.info, "TIDAL: abgebrochen", key: "tidal")
            } else {
                StatusCenter.post(.error, "TIDAL: " + ((error as? LocalizedError)?.errorDescription ?? "Fehler"), key: "tidal")
            }
        }
    }
}
