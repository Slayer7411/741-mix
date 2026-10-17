import Foundation

/// Bereinigung von Absturzberichten für die öffentliche Fassung (GitHub-Issue, Anzeige vor dem Senden). Reine Funktionen,
/// ohne Dateien und ohne Netz. Die Liste der Angaben, die bleiben, steht in `publicReport`; alles andere fällt weg.
enum CrashRedact {
    /// Angaben des Rechners und Nutzers, die im Bericht nicht vorkommen dürfen
    struct Names: Equatable {
        var home: String
        var user: String
        var fullName: String
        var computer: String

        static var current: Names {
            Names(home: NSHomeDirectory(), user: NSUserName(), fullName: NSFullUserName(),
                  computer: Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
        }
    }

    static let issueBase = "https://github.com/Slayer7411/MINOS-741/issues/new"
    static let issueMaxLength = 7000
    static let clipboardNote = "… vollständiger Bericht in der Zwischenablage"

    // MARK: Text

    /// Einzelner Text: Heimordner → `~`, Dateipfade → `<datei>`, Nutzer- und Rechnername, IP-, MAC- und UUID-Adressen
    static func text(_ s: String, names n: Names) -> String {
        var t = s
        if n.home.count > 1 { t = t.replacingOccurrences(of: n.home, with: "~") }
        // Pfad: beginnt am Textanfang, nach Leerzeichen, Anführungszeichen, Klammer, Gleichheitszeichen oder Doppelpunkt
        t = replace(t, #"(?:(?<=^|[\s"'(=:])/|~/)[^\s"'<>(),;\[\]]+"#, "<datei>")
        for name in [n.user, n.fullName, n.computer] where name.count >= 3 {
            t = t.replacingOccurrences(of: name, with: name == n.computer ? "<rechner>" : "<nutzer>", options: .caseInsensitive)
        }
        t = replace(t, #"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b"#, "<mac>")
        t = replace(t, #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "<ip>")
        t = replace(t, #"\b(?:[0-9A-Fa-f]{1,4}:){3,7}[0-9A-Fa-f]{1,4}\b"#, "<ip>")
        t = replace(t, #"\b[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\b"#, "<id>")
        return t
    }

    static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// Zeile aus dem Statusprotokoll bleibt nur, wenn die Bereinigung nichts ändern muss und sie keine Titel-Trenner,
    /// Pfade oder Audio-Dateinamen enthält (Künstler – Titel, Dateien mit Endung)
    static func keepsLogLine(_ s: String, names: Names) -> Bool {
        if text(s, names: names) != s { return false }
        if s.contains("–") || s.contains("—") || s.contains("·") || s.contains("/") || s.contains("\"") { return false }
        if replace(s, #"\.(?:wav|aif|aiff|mp3|m4a|flac|ogg|aac|wv)\b"#, "") != s { return false }
        return true
    }

    /// Letzte `limit` Zeilen, die die Regel bestehen (siehe `keepsLogLine`)
    static func logTail(_ lines: [String], names: Names, limit: Int = 20) -> [String] {
        Array(lines.filter { keepsLogLine($0, names: names) }.suffix(limit))
    }

    /// Einstellungen für die Anzeige: Kennungen von Geräten (Schlüssel endet auf UID / DeviceID) weg
    static func isDeviceKey(_ k: String) -> Bool {
        let l = k.lowercased()
        return l.hasSuffix("uid") || l.hasSuffix("deviceid")
    }

    // MARK: .ips

    /// .ips besteht aus zwei JSON-Objekten: Kopf (erste Zeile) und Körper (Rest). Ohne Kopf: ein Objekt
    static func parseIPS(_ text: String) -> (header: [String: Any], body: [String: Any])? {
        func object(_ s: String) -> [String: Any]? {
            guard let d = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let nl = text.firstIndex(of: "\n") else {
            guard let one = object(text) else { return nil }
            return ([:], one)
        }
        let head = String(text[..<nl]), rest = String(text[text.index(after: nl)...])
        if let h = object(head), let b = object(rest) { return (h, b) }
        guard let one = object(text) else { return nil }
        return ([:], one)
    }

    /// Öffentliche Fassung eines Berichts (englisch, für GitHub): Version, macOS, Prozessor, Ausnahme, Stapel des
    /// abgestürzten Threads (Symbolname + Versatz, ohne Bildpfade), letzte Protokollzeilen (nur wenn sie bestehen).
    /// Nicht enthalten: Pfade, Nutzer, Rechner, Geräte, Statusmeldungen mit Titeln
    static func publicReport(ips: String, status: [String], names n: Names) -> String? {
        guard let (h, b) = parseIPS(ips) else { return nil }
        func str(_ v: Any?) -> String {
            guard let v, !(v is NSNull) else { return "?" }
            return text("\(v)", names: n)
        }
        var os = str(h["os_version"])
        if let o = b["osVersion"] as? [String: Any] {
            os = "\(str(o["train"])) (\(str(o["build"])))"
        }
        var exc = "?"
        if let e = b["exception"] as? [String: Any] {
            let t = str(e["type"]), s = e["signal"].map { " (\(str($0)))" } ?? ""
            exc = t + s
        }
        var out = """
        MINOS-741 crash report (redacted)

        App:       \(str(h["app_version"] ?? b["app_version"])) (build \(str(h["build_version"] ?? b["build_version"])))
        macOS:     \(os)
        CPU:       \(str(b["cpuType"]))
        Model:     \(str(b["hardwareModel"]))
        Exception: \(exc)
        Captured:  \(str(b["captureTime"] ?? h["timestamp"]))

        Crashed thread:
        """
        let threads = (b["threads"] as? [[String: Any]]) ?? []
        let idx = (b["faultingThread"] as? Int) ?? threads.firstIndex { ($0["triggered"] as? Bool) == true } ?? 0
        if threads.indices.contains(idx) {
            let frames = (threads[idx]["frames"] as? [[String: Any]]) ?? []
            for (i, f) in frames.prefix(40).enumerated() {
                let loc = f["symbolLocation"] ?? f["imageOffset"]
                let sym = (f["symbol"] as? String).map { text($0, names: n) } ?? "?"
                out += "\n  \(i)  \(sym)" + (loc.map { "+\($0)" } ?? "")
            }
        } else {
            out += "\n  ?"
        }
        let tail = logTail(status, names: n)
        if !tail.isEmpty {
            out += "\n\nLast log lines (only lines that need no redaction):\n"
            out += tail.map { "  " + $0 }.joined(separator: "\n")
        }
        return out + "\n"
    }

    // MARK: Einstellungen

    /// Einstellungs-Wörterbuch als JSON ohne Geräte-Kennungen (verschachtelt)
    static func redactedSettings(_ value: Any) -> Any? {
        if let d = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in d where !isDeviceKey(k) {
                if let r = redactedSettings(v) { out[k] = r }
            }
            return out
        }
        if let a = value as? [Any] { return a.compactMap { redactedSettings($0) } }
        if let d = value as? Data { return d.base64EncodedString() }
        if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
        return value
    }

    // MARK: GitHub

    /// Titel für das Issue: „Crash: <Version> (<Build>) · <Ausnahme>“; unbekannte Teile fallen weg, sonst „Crash report“
    static func issueTitle(ips: String, names n: Names) -> String {
        guard let (h, b) = parseIPS(ips) else { return "Crash report" }
        func known(_ v: Any?) -> String? {
            guard let s = v as? String, !s.isEmpty, s != "?" else { return nil }
            return text(s, names: n)
        }
        var fields: [String] = []
        if let ver = known(h["app_version"] ?? b["app_version"]) {
            let build = known(h["build_version"] ?? b["build_version"])
            fields.append(build.map { "\(ver) (\($0))" } ?? ver)
        }
        if let exc = known((b["exception"] as? [String: Any])?["type"]) { fields.append(exc) }
        return fields.isEmpty ? "Crash report" : "Crash: " + fields.joined(separator: " · ")
    }

    /// `issues/new`-Adresse mit Titel, Text und Marke „crash“. Über `issueMaxLength` wird der Text gekürzt (dann
    /// Hinweis auf die Zwischenablage). Gibt außerdem zurück, ob gekürzt wurde.
    static func issueURL(title: String, body: String, maxLength: Int = issueMaxLength) -> (url: URL, truncated: Bool) {
        func make(_ b: String) -> String {
            "\(issueBase)?title=\(enc(String(title.prefix(120))))&body=\(enc(b))&labels=crash"
        }
        let full = make(body)
        if full.count <= maxLength { return (URL(string: full)!, false) }
        // größte Anzahl Zeichen, deren Adresse (mit Hinweis) noch passt
        let chars = Array(body)
        var lo = 0, hi = chars.count
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let candidate = make(String(chars[..<mid]) + "\n\n" + clipboardNote)
            if candidate.count <= maxLength { lo = mid } else { hi = mid - 1 }
        }
        return (URL(string: make(String(chars[..<lo]) + "\n\n" + clipboardNote))!, true)
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
}
