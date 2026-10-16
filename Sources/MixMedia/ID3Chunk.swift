import Foundation

/// ID3v2.4-Tag in WAV (Chunk `id3 `, dazu LIST INFO) und AIFF (Chunk `ID3 `): schreiben und lesen. Nur die Felder, die
/// MINOS kennt (Titel, Künstler, Album, Remixer, Label, Genre, Jahr, Kommentar, Tonart, BPM, Cover)
public enum ID3Chunk {
    /// gelesener Inhalt: Text-Frames (ID3-Kennung -> Text), Cover
    public struct Read: Equatable, Sendable {
        public var text: [String: String] = [:]
        public var picture: Data?

        /// Felder als `ExportTags` (ohne Cover-Wahl: Bild, falls vorhanden, sonst keins)
        public var tags: ExportTags {
            var t = ExportTags()
            t.title = text["TIT2"] ?? ""
            t.artist = text["TPE1"] ?? ""
            t.album = text["TALB"] ?? ""
            t.remixer = text["TPE4"] ?? ""
            t.label = text["TPUB"] ?? ""
            t.genre = text["TCON"] ?? ""
            t.key = text["TKEY"] ?? ""
            t.year = text["TDRC"].flatMap { Int($0.prefix(4)) }
            t.bpm = text["TBPM"].flatMap { Double($0) }
            t.comment = text["COMM"] ?? ""
            t.cover = picture.map { .image($0) } ?? .none
            return t
        }
    }

    // MARK: Schreiben

    /// ID3v2.4-Tag (Bytes), leere Felder fehlen
    public static func tagBytes(_ t: ExportTags, picture: Data?) -> Data {
        var frames = Data()
        func text(_ id: String, _ s: String) {
            guard !s.isEmpty else { return }
            frames.append(frame(id, [3] + Array(s.utf8)))
        }
        text("TIT2", t.title)
        text("TPE1", t.artist)
        text("TALB", t.album)
        text("TPE4", t.remixer)
        text("TPUB", t.label)
        text("TCON", t.genre)
        text("TKEY", t.key)
        if let y = t.year { text("TDRC", String(y)) }
        if let b = t.bpm, b > 0 { text("TBPM", b == b.rounded() ? String(Int(b)) : String(format: "%.2f", b)) }
        if !t.comment.isEmpty { frames.append(frame("COMM", [3] + Array("eng".utf8) + [0] + Array(t.comment.utf8))) }
        if let p = picture, !p.isEmpty {
            frames.append(frame("APIC", [3] + Array(ArtImage.mime(p).utf8) + [0, 3, 0] + Array(p)))
        }
        var head = Data("ID3".utf8) + Data([4, 0, 0])
        head.append(contentsOf: synchsafe(frames.count))
        return head + frames
    }

    /// Chunks an fertige WAV- oder AIFF-Datei anhängen und die Größe der Container-Form nachtragen. WAV: `id3 ` und
    /// LIST INFO, AIFF: `ID3 `
    public static func append(to url: URL, aiff: Bool, tags t: ExportTags, picture: Data?) throws {
        var add = Data()
        let tag = tagBytes(t, picture: picture)
        add.append(chunk(aiff ? "ID3 " : "id3 ", tag, bigEndian: aiff))
        if !aiff, let info = infoList(t) { add.append(info) }
        let h = try FileHandle(forUpdating: url)
        defer { try? h.close() }
        let end = try h.seekToEnd()
        try h.write(contentsOf: add)
        let size = UInt32(end + UInt64(add.count) - 8)
        try h.seek(toOffset: 4)
        try h.write(contentsOf: u32(size, bigEndian: aiff))
    }

    /// Kennung, Größe, Daten, Pad-Byte bei ungerader Länge
    static func chunk(_ id: String, _ data: Data, bigEndian: Bool) -> Data {
        var out = Data(id.utf8) + u32(UInt32(data.count), bigEndian: bigEndian) + data
        if data.count % 2 == 1 { out.append(0) }
        return out
    }

    /// LIST INFO (WAV): INAM Titel, IART Künstler, IPRD Album, ICMT Kommentar, IGNR Genre, ICRD Jahr
    static func infoList(_ t: ExportTags) -> Data? {
        let fields: [(String, String)] = [("INAM", t.title), ("IART", t.artist), ("IPRD", t.album), ("ICMT", t.comment),
                                          ("IGNR", t.genre), ("ICRD", t.year.map(String.init) ?? "")]
        var body = Data("INFO".utf8)
        for (id, s) in fields where !s.isEmpty {
            body.append(chunk(id, Data(s.utf8) + Data([0]), bigEndian: false))
        }
        guard body.count > 4 else { return nil }
        return chunk("LIST", body, bigEndian: false)
    }

    static func synchsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)]
    }

    static func u32(_ v: UInt32, bigEndian: Bool) -> Data {
        var x = bigEndian ? v.bigEndian : v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    static func frame(_ id: String, _ body: [UInt8]) -> Data {
        var d = Data(id.utf8) + Data(synchsafe(body.count)) + Data([0, 0])
        d.append(contentsOf: body)
        return d
    }

    // MARK: Lesen

    /// Chunks (Kennung, Datenstart, Länge) einer WAV- oder AIFF-Datei, ohne die Daten zu laden
    static func chunks(_ url: URL) -> [(id: String, at: UInt64, size: UInt64)]? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 12), head.count == 12 else { return nil }
        let form = String(decoding: head.prefix(4), as: UTF8.self), kind = String(decoding: head.suffix(4), as: UTF8.self)
        let aiff = form == "FORM" && (kind == "AIFF" || kind == "AIFC")
        guard aiff || (form == "RIFF" && kind == "WAVE") else { return nil }
        let total = (try? h.seekToEnd()) ?? 0
        var at: UInt64 = 12
        var out: [(id: String, at: UInt64, size: UInt64)] = []
        while at + 8 <= total {
            try? h.seek(toOffset: at)
            guard let hd = try? h.read(upToCount: 8), hd.count == 8 else { break }
            let id = String(decoding: hd.prefix(4), as: UTF8.self)
            let raw = Array(hd.suffix(4))
            let size = aiff ? (UInt64(raw[0]) << 24 | UInt64(raw[1]) << 16 | UInt64(raw[2]) << 8 | UInt64(raw[3]))
                            : (UInt64(raw[3]) << 24 | UInt64(raw[2]) << 16 | UInt64(raw[1]) << 8 | UInt64(raw[0]))
            out.append((id, at + 8, size))
            at += 8 + size + size % 2
        }
        return out
    }

    /// Inhalt aus dem ID3-Chunk (`id3 ` / `ID3 `), sonst LIST INFO (WAV); nil = kein Tag
    public static func read(_ url: URL) -> Read? {
        guard let list = chunks(url), let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        if let c = list.first(where: { $0.id == "id3 " || $0.id == "ID3 " }), c.size < 1 << 28,
           let d = try? read(h, at: c.at, count: Int(c.size)) {
            return parseID3(d)
        }
        guard let info = list.first(where: { $0.id == "LIST" }), info.size < 1 << 24,
              let d = try? read(h, at: info.at, count: Int(info.size)), d.prefix(4) == Data("INFO".utf8) else { return nil }
        var r = Read()
        let names = ["INAM": "TIT2", "IART": "TPE1", "IPRD": "TALB", "ICMT": "COMM", "IGNR": "TCON", "ICRD": "TDRC"]
        var p = 4
        while p + 8 <= d.count {
            let id = String(decoding: d[p..<p + 4], as: UTF8.self)
            let n = Int(d[p + 4]) | Int(d[p + 5]) << 8 | Int(d[p + 6]) << 16 | Int(d[p + 7]) << 24
            guard n >= 0, p + 8 + n <= d.count else { break }
            if let key = names[id] {
                let s = String(decoding: d[p + 8..<p + 8 + n].prefix { $0 != 0 }, as: UTF8.self)
                r.text[key] = s
            }
            p += 8 + n + n % 2
        }
        return r
    }

    /// eingebettetes Bild (ID3-Chunk), nil wenn keins
    public static func picture(_ url: URL) -> Data? { read(url)?.picture }

    static func read(_ h: FileHandle, at: UInt64, count: Int) throws -> Data {
        try h.seek(toOffset: at)
        return try h.read(upToCount: count) ?? Data()
    }

    /// ID3v2.3 / v2.4 aus Bytes
    public static func parseID3(_ d: Data) -> Read? {
        let b = [UInt8](d)
        guard b.count >= 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }
        let major = Int(b[3])
        let size = (Int(b[6]) << 21) | (Int(b[7]) << 14) | (Int(b[8]) << 7) | Int(b[9])
        var p = 10
        let end = min(b.count, 10 + size)
        var r = Read()
        while p + 10 <= end {
            let id = String(decoding: b[p..<p + 4], as: UTF8.self)
            if b[p] == 0 { break }
            let n = major == 4 ? (Int(b[p + 4]) << 21 | Int(b[p + 5]) << 14 | Int(b[p + 6]) << 7 | Int(b[p + 7]))
                               : (Int(b[p + 4]) << 24 | Int(b[p + 5]) << 16 | Int(b[p + 6]) << 8 | Int(b[p + 7]))
            let s = p + 10
            guard n >= 0, s + n <= end else { break }
            let body = Array(b[s..<s + n])
            p = s + n
            if id.hasPrefix("T"), id != "TXXX", let text = decodeText(body) {
                r.text[id] = text
            } else if id == "COMM", body.count > 4 {
                var q = 4
                if body[0] == 3 { while q < body.count, body[q] != 0 { q += 1 }; q += 1 } else { q = 4 }
                r.text["COMM"] = String(decoding: body[min(q, body.count)...], as: UTF8.self).trimmingCharacters(in: .controlCharacters)
            } else if id == "APIC", body.count > 2 {
                var q = 1
                while q < body.count, body[q] != 0 { q += 1 }
                q += 2   // Terminator der MIME-Angabe, Bildtyp
                if body[0] == 3 || body[0] == 0 { while q < body.count, body[q] != 0 { q += 1 } }
                q += 1
                if q < body.count { r.picture = Data(body[q...]) }
            }
        }
        return r
    }

    /// Text-Frame: Kodierung im ersten Byte (0 Latin-1, 1/2 UTF-16, 3 UTF-8), Nullen am Ende weg
    static func decodeText(_ body: [UInt8]) -> String? {
        guard let enc = body.first else { return nil }
        let raw = Array(body.dropFirst())
        let s: String?
        switch enc {
        case 0: s = String(bytes: raw, encoding: .isoLatin1)
        case 1, 2: s = String(bytes: raw, encoding: .utf16)
        default: s = String(bytes: raw, encoding: .utf8)
        }
        return s?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
