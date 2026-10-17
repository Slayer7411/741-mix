import Foundation
import MixCore
import MixEngine

/// Fernzugriff zum Analysieren (Zwei Macs). Dieser Mac antwortet auf Befehle des anderen (`PairDebugResponder`, nur bei
/// `PairSetup.remoteDebug`) und schickt Anfragen aus der Ordnerpost über die Verbindung (`PairDebug`).
/// Ordner `DataDir.local/pair-debug/`: Anfrage `outbox/<token>.json`, Antwort `inbox/<id>-<befehl>.json`,
/// Stand des anderen Macs alle 5 s in `peer-snapshot.json`. Bedienung: scripts/pairdebug.sh

/// Format der Ordnerpost (ohne Dateizugriff)
enum PairDebugFile {
    struct Request: Equatable {
        var command: String
        var args: String
        var token: String?
    }

    /// `{"command": "…", "args": "…" oder {…}, "token": "…"}`; args als Objekt wird als JSON-Text weitergegeben
    static func request(_ data: Data) -> Request? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = o["command"] as? String, !command.isEmpty else { return nil }
        var args = ""
        if let s = o["args"] as? String {
            args = s
        } else if let v = o["args"], !(v is NSNull),
                  let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) {
            args = String(decoding: d, as: UTF8.self)
        }
        return Request(command: command, args: args, token: o["token"] as? String)
    }

    /// `<id>-<befehl>.json`, der Befehl ohne Sonderzeichen
    static func inboxName(id: Int, command: String) -> String {
        let safe = String(command.prefix(40).map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        return "\(id)-\(safe).json"
    }

    /// `{"id", "ok", "command", "peer", "body", "token", "at"}`; body = geparstes JSON, sonst der Text
    static func reply(id: Int, ok: Bool, command: String, peer: String?, body: String, token: String?, at: Date? = nil) -> Data {
        var o: [String: Any] = ["id": id, "ok": ok, "command": command, "peer": opt(peer), "body": parsed(body)]
        if let token { o["token"] = token }
        if let at { o["at"] = timestamp(at) }
        return (try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    static func parsed(_ text: String) -> Any {
        guard let d = text.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        else { return text }
        return v
    }

    static func timestamp(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func opt(_ s: String?) -> Any { s.map { $0 as Any } ?? NSNull() }
}

/// Antworten auf die Befehle des anderen Macs. Jede Antwort ist JSON-Text (Fehler als JSON-Text-Zeichenkette)
@MainActor
enum PairDebugResponder {
    static func answer(command: String, args: String, mix: MixModel, allowed: Bool) -> (ok: Bool, body: String) {
        guard allowed else { return (false, text("Fernzugriff aus")) }
        switch command {
        case "ping":
            let o: [String: Any] = ["name": PairLink.computerName, "build": bundleValue("CFBundleVersion"),
                                    "version": bundleValue("CFBundleShortVersionString")]
            return (true, text(o))
        case "snapshot":
            return (true, text(snapshot(mix: mix)))
        case "status":
            let list: [[String: Any]] = StatusCenter.shared.recent.reversed().map { m in
                ["time": PairDebugFile.timestamp(m.updated), "level": "\(m.level)", "text": m.text,
                 "detail": PairDebugFile.opt(m.detail)]
            }
            return (true, text(list))
        case "prefs-get":
            return (true, text(jsonObject(mix.prefs)))
        case "prefs-set":
            return prefsSet(args: args, mix: mix)
        case "defaults-get":
            let key = args.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return (false, text("args: Schlüssel")) }
            return (true, text(keyValue(key)))
        case "defaults-set":
            return defaultsSet(args: args)
        default:
            return (false, text("unbekannter Befehl: \(command)"))
        }
    }

    /// Stand dieses Macs ohne Wellenform: Gerät, Takt, Decks, Ansicht, alle Einstellungen
    static func snapshot(mix: MixModel) -> [String: Any] {
        let s = mix.core.snapshot()
        var decks: [[String: Any]] = []
        for d in 0..<MixEngine.deckCount {
            let st = mix.deck(d)
            let tr = st.track
            let o: [String: Any] = [
                "letter": deckLetters[d],
                "visible": mix.visibleDecks.contains(d),
                "artist": field(tr) { $0.artist },
                "title": field(tr) { $0.title },
                "key": field(tr) { $0.keyText },
                "path": field(tr) { $0.path },
                "trackBPM": field(tr) { $0.bpm },
                "bpm": st.bpm,
                "pitchPct": st.tempoPct,
                "ratePct": st.rate * 100,
                "playing": st.playing,
                "sync": st.sync,
                "master": s.effectiveMaster == d,
                "position": mix.position(d),
                "duration": st.duration,
                "keylock": st.keylock,
            ]
            decks.append(o)
        }
        let clock: [String: Any] = ["clockBPM": s.clockBPM, "clockMaster": s.clockMaster, "linkEnabled": s.linkEnabled,
                                    "linkPeers": s.linkPeers, "linkForces": s.linkForces, "semiSync": s.semiSync,
                                    "metronome": s.metronome]
        let dev = mix.currentDevice
        let audio: [String: Any] = ["device": PairDebugFile.opt(dev?.name), "deviceUID": PairDebugFile.opt(dev?.uid),
                                    "sampleRate": mix.engine.outputRate, "coreRate": mix.engine.sampleRate,
                                    "bufferSize": mix.engine.deviceBufferFrames, "mixerMode": mix.mixerMode.rawValue,
                                    "running": mix.engine.running]
        var peer: Any = NSNull()
        if let q = PairLink.shared.peer { peer = ["name": q.name, "writes": q.writes, "decks": q.decks] as [String: Any] }
        return ["name": PairLink.computerName, "build": bundleValue("CFBundleVersion"), "pair": jsonObject(mix.prefs.ui.pair),
                "peer": peer, "clock": clock, "decks": decks, "focusedDeck": mix.focusedDeck, "audio": audio,
                "prefs": jsonObject(mix.prefs)]
    }

    /// Auftrag mit JSON-Objekt, verschmolzen in die aktuellen Einstellungen, dann live übernommen. Die Kopplung
    /// (`ui.pair`) bleibt, außer der Auftrag nennt sie ausdrücklich
    private static func prefsSet(args: String, mix: MixModel) -> (ok: Bool, body: String) {
        guard let patch = object(args) else { return (false, text("args: JSON-Objekt, z. B. {\"ui\":{\"zoom\":1.2}}")) }
        let defaults = jsonObject(AppPrefs()) as? [String: Any] ?? [:]
        let unknown = JSONMerge.unknownPaths(patch, reference: defaults)
        guard unknown.isEmpty else { return (false, text("unbekannte Schlüssel: " + unknown.joined(separator: ", "))) }
        let current = jsonObject(mix.prefs) as? [String: Any] ?? [:]
        do {
            let data = try JSONSerialization.data(withJSONObject: JSONMerge.merged(current, patch))
            var p = try JSONDecoder().decode(AppPrefs.self, from: data)
            if (patch["ui"] as? [String: Any])?["pair"] == nil { p.ui.pair = mix.prefs.ui.pair }
            mix.prefs = p
            return (true, text(jsonObject(p)))
        } catch {
            return (false, text("Decode: \(error)"))
        }
    }

    /// `{"key": …, "value": …}` -> UserDefaults (value null = löschen)
    private static func defaultsSet(args: String) -> (ok: Bool, body: String) {
        guard let o = object(args), let key = o["key"] as? String, !key.isEmpty, let value = o["value"] else {
            return (false, text("args: {\"key\": \"…\", \"value\": …}"))
        }
        if value is NSNull { E2E.defaults.removeObject(forKey: key) } else { E2E.defaults.set(value, forKey: key) }
        return (true, text(keyValue(key)))
    }

    private static func keyValue(_ key: String) -> [String: Any] {
        ["key": key, "value": plain(E2E.defaults.object(forKey: key) ?? NSNull())]
    }

    /// UserDefaults-Wert als JSON: Daten als Base64, Datum als ISO-Zeit
    private static func plain(_ v: Any) -> Any {
        switch v {
        case let d as Data: d.base64EncodedString()
        case let d as Date: PairDebugFile.timestamp(d)
        case let a as [Any]: a.map { plain($0) }
        case let d as [String: Any]: d.mapValues { plain($0) }
        default: v
        }
    }

    private static func field(_ t: Track?, _ f: (Track) -> Any) -> Any { t.map(f) ?? NSNull() }

    private static func bundleValue(_ key: String) -> String { (Bundle.main.infoDictionary?[key] as? String) ?? "" }

    private static func object(_ s: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }

    private static func jsonObject<T: Encodable>(_ v: T) -> Any {
        guard let d = try? JSONEncoder().encode(v), let o = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])
        else { return NSNull() }
        return o
    }

    /// NaN und Unendlich gibt JSON nicht her
    private static func sanitized(_ v: Any) -> Any {
        if let d = v as? Double, !d.isFinite { return NSNull() }
        if let d = v as? [String: Any] { return d.mapValues { sanitized($0) } }
        if let a = v as? [Any] { return a.map { sanitized($0) } }
        return v
    }

    static func text(_ v: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: sanitized(v), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return "\"Antwort nicht darstellbar\"" }
        return String(decoding: d, as: UTF8.self)
    }
}

/// Ordnerpost auf diesem Mac: Anfragen aus `outbox/` über die Verbindung an den anderen Mac, Antworten nach `inbox/`,
/// Stand des anderen Macs nach `peer-snapshot.json`. Läuft nur, solange der Zwei-Mac-Modus an ist
@MainActor
final class PairDebug {
    static let shared = PairDebug()
    static var dir: URL { DataDir.local.appendingPathComponent("pair-debug", isDirectory: true) }
    static var outbox: URL { dir.appendingPathComponent("outbox", isDirectory: true) }
    static var inbox: URL { dir.appendingPathComponent("inbox", isDirectory: true) }
    static var snapshotFile: URL { dir.appendingPathComponent("peer-snapshot.json") }
    /// Stand des anderen Macs alle so viele Sekunden, solange verbunden
    static let snapshotInterval: TimeInterval = 5
    /// ohne Antwort nach so vielen Sekunden abschließen
    static let replyTimeout: TimeInterval = 30

    private struct Pending {
        let command: String
        /// Token aus der Anfrage (Antwort trägt es zurück); nil bei Stand-Abfragen
        let token: String?
        let snapshot: Bool
        let sent: Date
    }

    private var timer: Timer?
    /// fortlaufende IDs ab der Uhrzeit: Antworten früherer Starts bleiben unberührt
    private var nextID = Int(Date().timeIntervalSince1970)
    private var pending: [Int: Pending] = [:]
    private var snapshotID: Int?
    private var lastSnapshot = Date.distantPast

    private var peerName: String? { PairLink.shared.peer?.name }

    /// Zwei-Mac-Modus an: Ordner anlegen, alle 0,5 s nachsehen
    func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: Self.outbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.inbox, withIntermediateDirectories: true)
        let t = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { PairDebug.shared.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Zwei-Mac-Modus aus: offene Anfragen bekommen eine Absage
    func stop() {
        timer?.invalidate()
        timer = nil
        failPending("Zwei-Mac aus")
    }

    /// Verbindung verloren: offene Anfragen bekommen eine Absage
    func connectionLost() { failPending("Verbindung getrennt") }

    private func tick() {
        expire()
        let link = PairLink.shared
        if link.connected, snapshotID == nil, Date().timeIntervalSince(lastSnapshot) >= Self.snapshotInterval {
            lastSnapshot = Date()
            let id = newID()
            pending[id] = Pending(command: "snapshot", token: nil, snapshot: true, sent: Date())
            snapshotID = id
            link.send(.debugRequest(id: id, command: "snapshot", args: ""))
        }
        let names = (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []
        for url in names.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            handle(url)
        }
    }

    /// eine Anfrage aus dem Ordner: Datei weg, dann über die Verbindung (oder Absage)
    private func handle(_ url: URL) {
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard let data, let req = PairDebugFile.request(data) else {
            inboxReply(id: newID(), command: "fehler", ok: false, body: "Anfrage unlesbar", token: nil)
            return
        }
        guard PairLink.shared.connected else {
            inboxReply(id: newID(), command: req.command, ok: false, body: "keine Verbindung", token: req.token)
            return
        }
        let id = newID()
        pending[id] = Pending(command: req.command, token: req.token, snapshot: false, sent: Date())
        PairLink.shared.send(.debugRequest(id: id, command: req.command, args: req.args))
    }

    /// Antwort vom anderen Mac
    func received(id: Int, ok: Bool, body: String) {
        guard let p = pending.removeValue(forKey: id) else { return }
        if p.snapshot {
            if snapshotID == id { snapshotID = nil }
            write(PairDebugFile.reply(id: id, ok: ok, command: p.command, peer: peerName, body: body, token: nil, at: Date()),
                  to: Self.snapshotFile)
        } else {
            inboxReply(id: id, command: p.command, ok: ok, body: body, token: p.token)
        }
    }

    private func expire() {
        let now = Date()
        for (id, p) in pending where now.timeIntervalSince(p.sent) > Self.replyTimeout {
            pending[id] = nil
            if p.snapshot {
                if snapshotID == id { snapshotID = nil }
            } else {
                inboxReply(id: id, command: p.command, ok: false, body: "keine Antwort", token: p.token)
            }
        }
    }

    private func failPending(_ reason: String) {
        for (id, p) in pending where !p.snapshot {
            inboxReply(id: id, command: p.command, ok: false, body: reason, token: p.token)
        }
        pending.removeAll()
        snapshotID = nil
    }

    private func inboxReply(id: Int, command: String, ok: Bool, body: String, token: String?) {
        let data = PairDebugFile.reply(id: id, ok: ok, command: command, peer: peerName, body: body, token: token)
        write(data, to: Self.inbox.appendingPathComponent(PairDebugFile.inboxName(id: id, command: command)))
    }

    private func newID() -> Int {
        nextID += 1
        return nextID
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
