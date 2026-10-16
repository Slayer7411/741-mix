import AppKit
import CryptoKit
import Foundation
import Network
import Security

/// TIDAL-Anmeldung: OAuth 2.0 Authorization Code mit PKCE für einen öffentlichen Client (kein Client-Secret).
/// Quellen: Sicherheitsschema „Authorization_Code_PKCE“ der API-Referenz (tidal-music.github.io/tidal-api-reference,
/// tidal-api-oas.json: login.tidal.com/authorize, auth.tidal.com/v1/oauth2/token) und developer.tidal.com.
/// Tokens nur im Schlüsselbund, nie in Logs oder Statusmeldungen.
enum TidalAuth {
    static let authorizeEndpoint = "https://login.tidal.com/authorize"
    static let tokenEndpoint = "https://auth.tidal.com/v1/oauth2/token"
    static let redirectURI = "http://localhost:7412/tidal/callback"
    static let callbackPort: UInt16 = 7412
    /// user.read (Land), playlists.read/write, search.read: die vom TIDAL-Portal freigegebenen Scopes (Stand Registrierung)
    /// r_usr/w_usr stehen im Schema der Referenz, sind aber INTERNAL und nicht freigegeben
    static let scopes = ["user.read", "playlists.read", "playlists.write", "search.read"]
    /// Wartezeit im Browser, danach bricht die Anmeldung ab
    static let timeout: TimeInterval = 300

    static var signedIn: Bool { TidalKeychain.load() != nil }

    static func signOut() { TidalKeychain.delete() }

    /// Anmeldung: Browser öffnen, Rücksprung auf 127.0.0.1 abwarten, Code gegen Tokens tauschen, im Schlüsselbund speichern
    static func signIn(clientID: String) async throws -> TidalTokens {
        let id = clientID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { throw TidalError.noClientID }
        let verifier = TidalPKCE.verifier()
        let state = TidalPKCE.verifier()
        guard let url = authorizeURL(clientID: id, challenge: TidalPKCE.challenge(verifier), state: state) else {
            throw TidalError.badResponse
        }
        let server = TidalCallbackServer()
        let query: [String: String] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<[String: String], Error>) in
                do {
                    try server.start(timeout: timeout) { c.resume(with: $0) }
                } catch {
                    c.resume(throwing: error)
                    return
                }
                Task { @MainActor in _ = NSWorkspace.shared.open(url) }
            }
        } onCancel: {
            server.stop(TidalError.cancelled)
        }
        guard query["state"] == state else { throw TidalError.state }
        if let e = query["error"] { throw TidalError.denied(e) }
        guard let code = query["code"] else { throw TidalError.badResponse }
        let data = try await postToken(form([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", id), ("code_verifier", verifier),
        ]))
        let t = try tokens(from: data)
        _ = TidalKeychain.save(t)
        return t
    }

    /// neuer Access-Token über den Refresh-Token; das Ergebnis wird gespeichert
    static func refresh(_ t: TidalTokens, clientID: String) async throws -> TidalTokens {
        let data = try await postToken(form([
            ("grant_type", "refresh_token"), ("refresh_token", t.refresh), ("client_id", clientID),
        ]))
        let n = try tokens(from: data, keepRefresh: t.refresh)
        _ = TidalKeychain.save(n)
        return n
    }

    static func authorizeURL(clientID: String, challenge: String, state: String) -> URL? {
        var c = URLComponents(string: authorizeEndpoint)
        c?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return c?.url
    }

    /// Antwort des Token-Endpunkts; ohne neuen Refresh-Token bleibt der alte
    static func tokens(from data: Data, now: Date = Date(), keepRefresh: String? = nil) throws -> TidalTokens {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        let r = try d.decode(TokenResponse.self, from: data)
        guard let refresh = r.refreshToken ?? keepRefresh else { throw TidalError.badResponse }
        return TidalTokens(access: r.accessToken, refresh: refresh, expires: now.addingTimeInterval(r.expiresIn ?? 3600))
    }

    /// application/x-www-form-urlencoded
    static func form(_ fields: [(String, String)]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let s = fields.map { k, v in
            [k, v].map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "=")
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
    }

    private static func postToken(_ body: Data) async throws -> Data {
        guard let url = URL(string: tokenEndpoint) else { throw TidalError.badResponse }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = body
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw TidalError.http(code, TidalClient.errorDetail(data)) }
        return data
    }
}

/// Tokens im Schlüsselbund (Dienst „MINOS-741 TIDAL“)
struct TidalTokens: Codable, Equatable, Sendable {
    var access: String
    var refresh: String
    var expires: Date
    /// mit einer Minute Reserve gültig
    var fresh: Bool { expires.timeIntervalSinceNow > 60 }
}

enum TidalKeychain {
    static let service = "MINOS-741 TIDAL"

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "tokens"]
    }

    static func load() -> TidalTokens? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(TidalTokens.self, from: d)
    }

    @discardableResult
    static func save(_ t: TidalTokens) -> Bool {
        guard let d = try? JSONEncoder().encode(t) else { return false }
        delete()
        var q = query()
        q[kSecValueData as String] = d
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func delete() { SecItemDelete(query() as CFDictionary) }
}

/// PKCE nach RFC 7636 (Verfahren S256)
enum TidalPKCE {
    /// zufälliger Verifier: 32 Byte, base64url ohne Auffüllung (43 Zeichen)
    static func verifier() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return base64url(Data(b))
    }

    static func challenge(_ verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum TidalError: LocalizedError {
    case noClientID
    case http(Int, String)
    case badResponse
    case state
    case denied(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noClientID: String(localized: "Client-ID fehlt (⌘, → Browser)")
        case let .http(code, detail):
            switch code {
            case 401: String(localized: "nicht angemeldet – erneut anmelden")
            case 403: String(localized: "Zugriff verweigert (Scopes der App prüfen)")
            case 429: String(localized: "Ratenlimit erreicht")
            default: "HTTP \(code)" + (detail.isEmpty ? "" : " · \(detail)")
            }
        case .badResponse: String(localized: "Antwort von TIDAL unlesbar")
        case .state: String(localized: "Anmeldung abgelehnt (state stimmt nicht)")
        case let .denied(e): String(localized: "Anmeldung abgelehnt: \(e)")
        case .timeout: String(localized: "keine Anmeldung im Browser (Zeitlimit)")
        case .cancelled: String(localized: "abgebrochen")
        }
    }
}

/// Einmaliger Empfang des Rücksprungs: nur Loopback, Pfad /tidal/callback; danach Antwortseite und Ende
final class TidalCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "minos.tidal.callback")
    private var listener: NWListener?
    /// nur auf `queue`
    private var finish: ((Result<[String: String], Error>) -> Void)?

    func start(timeout: TimeInterval, _ done: @escaping (Result<[String: String], Error>) -> Void) throws {
        guard let port = NWEndpoint.Port(rawValue: TidalAuth.callbackPort) else { throw TidalError.badResponse }
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let l = try NWListener(using: params, on: port)
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.stateUpdateHandler = { [weak self] st in
            if case let .failed(e) = st { self?.queue.async { self?.end(.failure(e)) } }
        }
        queue.sync { finish = done }
        listener = l
        l.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.end(.failure(TidalError.timeout)) }
    }

    func stop(_ e: Error) {
        queue.async { [weak self] in self?.end(.failure(e)) }
    }

    /// nur auf `queue`
    private func end(_ r: Result<[String: String], Error>) {
        guard let f = finish else { return }
        finish = nil
        listener?.cancel()
        listener = nil
        f(r)
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { conn.cancel(); return }
            let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            let target = parts.count >= 2 ? String(parts[1]) : ""
            let u = URLComponents(string: "http://127.0.0.1" + target)
            guard u?.path == "/tidal/callback" else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            var q: [String: String] = [:]
            for i in u?.queryItems ?? [] {
                if let v = i.value { q[i.name] = v }
            }
            let ok = q["code"] != nil
            self.respond(conn, status: "200 OK", body: ok
                ? "<!doctype html><meta charset=utf-8><title>MINOS-741</title><p style=\"font-family:-apple-system\">MINOS-741: angemeldet, Fenster schließen</p>"
                : "<!doctype html><meta charset=utf-8><title>MINOS-741</title><p style=\"font-family:-apple-system\">MINOS-741: Anmeldung abgebrochen, Fenster schließen</p>")
            if ok || q["error"] != nil { self.end(.success(q)) }
        }
    }

    private func respond(_ c: NWConnection, status: String, body: String) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in c.cancel() })
    }
}
