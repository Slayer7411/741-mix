import Foundation

/// TIDAL-API v2 (JSON:API, openapi.tidal.com/v2): Land des Kontos, Suche, Track-Künstler, Playlists.
/// Referenz: tidal-music.github.io/tidal-api-reference (GET /users/{id}, GET /searchResults, GET /tracks,
/// POST /playlists, POST /playlists/{id}/relationships/items). Anfragen seriell mit Abstand; 429 wartet Retry-After.
actor TidalClient {
    static let base = "https://openapi.tidal.com/v2"
    static let mediaType = "application/vnd.api+json"
    /// Abstand zwischen zwei Anfragen (Ratenlimit)
    static let spacing: TimeInterval = 0.25

    private let clientID: String
    private var tokens: TidalTokens
    private var lastCall = Date.distantPast

    init(clientID: String, tokens: TidalTokens) {
        self.clientID = clientID
        self.tokens = tokens
    }

    /// Land des Kontos (countryCode für Suche und Playlists)
    func country() async throws -> String? {
        Self.parseCountry(try await send("GET", "/users/me"))
    }

    /// Suchtreffer zu „Artist Titel“ (erste zehn, Rangfolge der Suche), mit Künstlern
    func search(_ query: String, country: String) async throws -> [TidalCandidate] {
        let data = try await send("GET", "/searchResults", query: [
            URLQueryItem(name: "filter[query]", value: String(query.prefix(200))),
            URLQueryItem(name: "include", value: "tracks"),
            URLQueryItem(name: "countryCode", value: country),
        ])
        let cands = Array(Self.parseSearch(data).prefix(10))
        guard !cands.isEmpty else { return [] }
        let names = try await artists(of: cands.map(\.id), country: country)
        return cands.map { c in
            var c = c
            c.artist = names[c.id] ?? ""
            return c
        }
    }

    /// neue Playlist des Kontos (UNLISTED: nicht öffentlich auffindbar); liefert die ID
    func createPlaylist(name: String, description: String) async throws -> String {
        let data = try await send("POST", "/playlists", body: Self.playlistBody(name: name, description: description))
        guard let id = Self.playlistID(data) else { throw TidalError.badResponse }
        return id
    }

    /// Titel in Blöcken zu je 50 (maxItems der Referenz)
    func addTracks(_ ids: [String], to playlist: String) async throws {
        let pid = playlist.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? playlist
        for start in stride(from: 0, to: ids.count, by: 50) {
            let part = Array(ids[start..<min(start + 50, ids.count)])
            _ = try await send("POST", "/playlists/\(pid)/relationships/items", body: Self.itemsBody(part))
        }
    }

    /// Künstler je Track-ID (Blöcke zu je 20, maxItems von filter[id])
    private func artists(of ids: [String], country: String) async throws -> [String: String] {
        var out: [String: String] = [:]
        for start in stride(from: 0, to: ids.count, by: 20) {
            let part = ids[start..<min(start + 20, ids.count)]
            let data = try await send("GET", "/tracks", query: [
                URLQueryItem(name: "filter[id]", value: part.joined(separator: ",")),
                URLQueryItem(name: "include", value: "artists"),
                URLQueryItem(name: "countryCode", value: country),
            ])
            out.merge(Self.parseArtists(data)) { a, _ in a }
        }
        return out
    }

    // MARK: - Anfragen

    private func accessToken() async throws -> String {
        if !tokens.fresh {
            tokens = try await TidalAuth.refresh(tokens, clientID: clientID)
        }
        return tokens.access
    }

    /// Eine Anfrage. 429: nach Retry-After (Standard 2 s) wiederholen, höchstens fünfmal. 401: einmal neu anmelden
    /// über den Refresh-Token. Tokens tauchen in keiner Fehlermeldung auf.
    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var refreshed = false
        var waits = 0
        while true {
            try Task.checkCancellation()
            let wait = lastCall.addingTimeInterval(Self.spacing).timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            lastCall = Date()
            var c = URLComponents(string: Self.base + path)
            if !query.isEmpty { c?.queryItems = query }
            guard let url = c?.url else { throw TidalError.badResponse }
            var r = URLRequest(url: url)
            r.httpMethod = method
            let token = try await accessToken()
            r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            r.setValue(Self.mediaType, forHTTPHeaderField: "Accept")
            if let body {
                r.httpBody = body
                r.setValue(Self.mediaType, forHTTPHeaderField: "Content-Type")
            }
            r.timeoutInterval = 30
            let (data, resp) = try await URLSession.shared.data(for: r)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            switch code {
            case 200..<300:
                return data
            case 429 where waits < 5:
                waits += 1
                let s = Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(nanoseconds: UInt64(min(max(s, 1), 60) * 1e9))
            case 401 where !refreshed:
                refreshed = true
                tokens = try await TidalAuth.refresh(tokens, clientID: clientID)
            default:
                throw TidalError.http(code, Self.errorDetail(data))
            }
        }
    }

    /// nur das Feld „error“ / „code“ der Fehlerantwort, nie Tokens
    static func errorDetail(_ d: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "" }
        if let e = o["error"] as? String { return e }
        if let errs = o["errors"] as? [[String: Any]], let c = errs.first?["code"] as? String { return c }
        return ""
    }

    // MARK: - Anfrage- und Antwortformate (ohne Netz prüfbar)

    /// JSON:API-Körper „Playlist anlegen“
    static func playlistBody(name: String, description: String) -> Data {
        json(["data": ["type": "playlists",
                       "attributes": ["name": name, "description": description, "accessType": "UNLISTED"]]])
    }

    /// JSON:API-Körper „Titel hinzufügen“ (Relationship items, Typ tracks)
    static func itemsBody(_ ids: [String]) -> Data {
        json(["data": ids.map { ["id": $0, "type": "tracks"]}])
    }

    static func parseCountry(_ d: Data) -> String? {
        ((object(d)?["data"] as? [String: Any])?["attributes"] as? [String: Any])?["country"] as? String
    }

    static func playlistID(_ d: Data) -> String? {
        (object(d)?["data"] as? [String: Any])?["id"] as? String
    }

    /// Track-Treffer aus der Suche (included, Typ tracks), Reihenfolge der Suche
    static func parseSearch(_ d: Data) -> [TidalCandidate] {
        resources(d, type: "tracks").compactMap { r in
            guard let id = r["id"] as? String else { return nil }
            let a = r["attributes"] as? [String: Any] ?? [:]
            return TidalCandidate(id: id, title: a["title"] as? String ?? "", artist: "",
                                  duration: isoDuration(a["duration"] as? String ?? ""))
        }
    }

    /// Track-ID -> Künstlernamen („A, B“) aus included (Typ artists) und den Beziehungen der Tracks
    static func parseArtists(_ d: Data) -> [String: String] {
        var names: [String: String] = [:]
        for a in resources(d, type: "artists") {
            if let id = a["id"] as? String, let n = (a["attributes"] as? [String: Any])?["name"] as? String { names[id] = n }
        }
        var out: [String: String] = [:]
        let tracks = (object(d)?["data"] as? [[String: Any]]) ?? []
        for t in tracks {
            guard let id = t["id"] as? String else { continue }
            let linked = ((t["relationships"] as? [String: Any])?["artists"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let list = linked.compactMap { $0["id"] as? String }.compactMap { names[$0] }
            if !list.isEmpty { out[id] = list.joined(separator: ", ") }
        }
        return out
    }

    /// ISO 8601 („PT2M58S“, „PT1H3.5S“) in Sekunden; unlesbar = 0
    static func isoDuration(_ s: String) -> Double {
        var total = 0.0
        var num = ""
        var inTime = false
        for ch in s.uppercased() {
            switch ch {
            case "P": continue
            case "T": inTime = true
            case "0"..."9", ".": num.append(ch)
            case "H": total += (Double(num) ?? 0) * 3600; num = ""
            case "M": total += inTime ? (Double(num) ?? 0) * 60 : 0; num = ""
            case "S": total += Double(num) ?? 0; num = ""
            default: return 0
            }
        }
        return total
    }

    private static func object(_ d: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    private static func resources(_ d: Data, type: String) -> [[String: Any]] {
        ((object(d)?["included"] as? [[String: Any]]) ?? []).filter { $0["type"] as? String == type }
    }

    private static func json(_ o: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }
}
