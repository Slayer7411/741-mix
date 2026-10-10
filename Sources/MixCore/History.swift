import Foundation

/// Ein gespielter Track in einer Session (wie Traktors History: Deck, Startzeit, Spieldauer).
public struct HistoryEntry: Codable, Hashable, Identifiable, Sendable {
    public var id = UUID()
    public var key: String
    public var title: String
    public var artist: String
    public var bpm: Double
    public var keyText: String
    public var deck: Int
    public var start: Date
    public var duration: Double

    public init(key: String, title: String, artist: String, bpm: Double, keyText: String, deck: Int, start: Date, duration: Double) {
        self.key = key; self.title = title; self.artist = artist; self.bpm = bpm
        self.keyText = keyText; self.deck = deck; self.start = start; self.duration = duration
    }
}

public struct HistorySession: Identifiable, Hashable, Sendable {
    public enum Source: String, Sendable { case live = "741", traktor = "Traktor" }
    public var id: String { url.path }
    public var url: URL
    public var date: Date
    public var source: Source

    public init(url: URL, date: Date, source: Source) {
        self.url = url; self.date = date; self.source = source
    }

    /// Datum aus Traktors Dateiname „history_2026y10m10d_09h05m33s.nml“ bzw. eigenem „history_2026-10-10_090533.json“
    public static func date(fromFileName name: String) -> Date? {
        let digits = name.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard digits.count >= 6 else { return nil }
        // eigenes Format: 2026 10 10 090533
        if digits.count == 4, digits[3] > 9999 {
            let t = digits[3]
            return DateComponents(calendar: Calendar(identifier: .gregorian), year: digits[0], month: digits[1], day: digits[2],
                                  hour: t / 10000, minute: t / 100 % 100, second: t % 100).date
        }
        return DateComponents(calendar: Calendar(identifier: .gregorian), year: digits[0], month: digits[1], day: digits[2],
                              hour: digits[3], minute: digits[4], second: digits[5]).date
    }
}

/// Liest eine Traktor-History-NML (COLLECTION + PLAYLIST mit EXTENDEDDATA: DECK, DURATION, STARTDATE, STARTTIME).
public final class TraktorHistoryParser: NSObject, XMLParserDelegate {
    private var tracks: [String: (title: String, artist: String, bpm: Double, key: String)] = [:]
    private var cur: (title: String, artist: String, bpm: Double, key: String, loc: String)?
    private var inCollection = false
    private var inPlaylist = false
    private var pendingKey: String?
    private var entries: [HistoryEntry] = []

    public static func parse(url: URL) -> [HistoryEntry] {
        guard let x = XMLParser(contentsOf: url) else { return [] }
        let p = TraktorHistoryParser()
        x.delegate = p
        x.parse()
        return p.entries
    }

    /// STARTDATE = Jahr<<16 | Monat<<8 | Tag, STARTTIME = Sekunden seit Mitternacht
    static func date(_ d: Int, _ t: Int) -> Date? {
        DateComponents(calendar: Calendar(identifier: .gregorian), year: d >> 16, month: (d >> 8) & 0xFF, day: d & 0xFF,
                       hour: t / 3600, minute: t / 60 % 60, second: t % 60).date
    }

    public func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?,
                       attributes a: [String: String] = [:]) {
        switch el {
        case "COLLECTION": inCollection = true
        case "ENTRY" where inCollection: cur = (a["TITLE"] ?? "", a["ARTIST"] ?? "", 0, "", "")
        case "LOCATION" where inCollection: cur?.loc = (a["VOLUME"] ?? "") + (a["DIR"] ?? "") + (a["FILE"] ?? "")
        case "TEMPO" where inCollection: cur?.bpm = Double(a["BPM"] ?? "") ?? 0
        case "INFO" where inCollection: cur?.key = a["KEY"] ?? ""
        case "PLAYLIST": inPlaylist = true
        case "PRIMARYKEY" where inPlaylist: pendingKey = a["KEY"]
        case "EXTENDEDDATA" where inPlaylist:
            guard let k = pendingKey else { return }
            let t = tracks[k]
            let start = Self.date(Int(a["STARTDATE"] ?? "") ?? 0, Int(a["STARTTIME"] ?? "") ?? 0) ?? .distantPast
            entries.append(HistoryEntry(key: k, title: t?.title ?? (k as NSString).lastPathComponent, artist: t?.artist ?? "",
                                        bpm: t?.bpm ?? 0, keyText: t?.key ?? "", deck: Int(a["DECK"] ?? "") ?? 0,
                                        start: start, duration: Double(a["DURATION"] ?? "") ?? 0))
            pendingKey = nil
        default: break
        }
    }

    public func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        switch el {
        case "COLLECTION": inCollection = false
        case "ENTRY" where inCollection:
            if let c = cur { tracks[c.loc] = (c.title, c.artist, c.bpm, c.key) }
            cur = nil
        case "PLAYLIST": inPlaylist = false
        default: break
        }
    }
}

/// Roh-ENTRY-Blöcke einer collection.nml je Track-Schlüssel – damit Exporte (History, Playlists)
/// die Einträge unverändert übernehmen (Cues, Tags, AUDIO_ID …), genau wie Traktor.
public struct NMLEntryIndex: Sendable {
    public private(set) var raw: [String: String] = [:]

    public init() {}

    public init(nmlText s: String) {
        guard let c0 = s.range(of: "<COLLECTION"), let c1 = s.range(of: "</COLLECTION>") else { return }
        var cursor = c0.upperBound
        while let a = s.range(of: "<ENTRY ", range: cursor..<c1.lowerBound),
              let b = s.range(of: "</ENTRY>", range: a.upperBound..<c1.lowerBound) {
            let block = String(s[a.lowerBound..<b.upperBound])
            if let k = Self.key(of: block) { raw[k] = block }
            cursor = b.upperBound
        }
    }

    /// Schlüssel VOLUME + DIR + FILE aus dem LOCATION-Element
    static func key(of block: String) -> String? {
        guard let l = block.range(of: "<LOCATION ") else { return nil }
        let tail = block[l.upperBound...]
        func attr(_ n: String) -> String? {
            guard let r = tail.range(of: " \(n)=\"") ?? (tail.hasPrefix("\(n)=\"") ? tail.range(of: "\(n)=\"") : nil) else { return nil }
            let rest = tail[r.upperBound...]
            guard let e = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<e])
        }
        guard let dir = attr("DIR"), let file = attr("FILE") else { return nil }
        return XMLText.unescape((attr("VOLUME") ?? "") + dir + file)
    }
}

enum XMLText {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Schreibt eine History-Session im Traktor-Format (history_JJJJyMMmTTd_HHhMMmSSs.nml).
public enum TraktorHistoryWriter {
    public static func fileName(for d: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return String(format: "history_%04dy%02dm%02dd_%02dh%02dm%02ds.nml", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func startFields(_ d: Date) -> (date: Int, time: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return ((c.year! << 16) | (c.month! << 8) | c.day!, c.hour! * 3600 + c.minute! * 60 + c.second!)
    }

    /// Minimaler ENTRY, falls der Track nicht in der Collection steht
    static func fallbackEntry(_ e: HistoryEntry) -> String {
        let parts = e.key.components(separatedBy: "/:")
        let volume = parts.first ?? ""
        let file = parts.last ?? ""
        let dir = "/:" + parts.dropFirst().dropLast().map { $0 + "/:" }.joined()
        return "<ENTRY TITLE=\"\(XMLText.escape(e.title))\" ARTIST=\"\(XMLText.escape(e.artist))\">"
            + "<LOCATION DIR=\"\(XMLText.escape(dir))\" FILE=\"\(XMLText.escape(file))\" VOLUME=\"\(XMLText.escape(volume))\" VOLUMEID=\"\(XMLText.escape(volume))\"></LOCATION>\n"
            + "<INFO KEY=\"\(XMLText.escape(e.keyText))\"></INFO>\n"
            + (e.bpm > 0 ? "<TEMPO BPM=\"\(String(format: "%.6f", e.bpm))\" BPM_QUALITY=\"100.000000\"></TEMPO>\n" : "")
            + "</ENTRY>"
    }

    public static func nml(entries: [HistoryEntry], index: NMLEntryIndex, uuid: String) -> String {
        var seen = Set<String>()
        var collection: [String] = []
        for e in entries where !seen.contains(e.key) {
            seen.insert(e.key)
            collection.append(index.raw[e.key] ?? fallbackEntry(e))
        }
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\" ?>\n"
        out += "<NML VERSION=\"19\"><HEAD COMPANY=\"www.native-instruments.com\" PROGRAM=\"Traktor\"></HEAD>\n"
        out += "<COLLECTION ENTRIES=\"\(collection.count)\">" + collection.joined(separator: "\n") + "\n</COLLECTION>\n"
        out += "<SETS ENTRIES=\"0\"></SETS>\n"
        out += "<PLAYLISTS><NODE TYPE=\"FOLDER\" NAME=\"$ROOT\"><SUBNODES COUNT=\"1\"><NODE TYPE=\"PLAYLIST\" NAME=\"HISTORY\">"
        out += "<PLAYLIST ENTRIES=\"\(entries.count)\" TYPE=\"PROTOCOL\" UUID=\"\(uuid)\">"
        for e in entries {
            let s = startFields(e.start)
            out += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(XMLText.escape(e.key))\"></PRIMARYKEY>\n"
            out += "<EXTENDEDDATA DECK=\"\(e.deck)\" DURATION=\"\(String(format: "%.6f", e.duration))\" EXTENDEDTYPE=\"HistoryData\" PLAYEDPUBLIC=\"1\" STARTDATE=\"\(s.date)\" STARTTIME=\"\(s.time)\"></EXTENDEDDATA>\n"
            out += "</ENTRY>\n"
        }
        out += "</PLAYLIST>\n</NODE>\n</SUBNODES>\n</NODE>\n</PLAYLISTS>\n<INDEXING></INDEXING>\n</NML>\n"
        return out
    }
}

/// Schreibt eine normale Playlist (TYPE="LIST") im Traktor-NML-Format – in Traktor per Import öffnen.
public enum TraktorPlaylistWriter {
    public static func nml(name: String, entries: [HistoryEntry], index: NMLEntryIndex) -> String {
        var seen = Set<String>()
        var collection: [String] = []
        for e in entries where !seen.contains(e.key) {
            seen.insert(e.key)
            collection.append(index.raw[e.key] ?? TraktorHistoryWriter.fallbackEntry(e))
        }
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\" ?>\n"
        out += "<NML VERSION=\"19\"><HEAD COMPANY=\"www.native-instruments.com\" PROGRAM=\"Traktor\"></HEAD>\n"
        out += "<COLLECTION ENTRIES=\"\(collection.count)\">" + collection.joined(separator: "\n") + "\n</COLLECTION>\n"
        out += "<SETS ENTRIES=\"0\"></SETS>\n"
        out += "<PLAYLISTS><NODE TYPE=\"FOLDER\" NAME=\"$ROOT\"><SUBNODES COUNT=\"1\"><NODE TYPE=\"PLAYLIST\" NAME=\"\(XMLText.escape(name))\">"
        out += "<PLAYLIST ENTRIES=\"\(entries.count)\" TYPE=\"LIST\" UUID=\"\(uuid)\">"
        for e in entries {
            out += "<ENTRY><PRIMARYKEY TYPE=\"TRACK\" KEY=\"\(XMLText.escape(e.key))\"></PRIMARYKEY>\n</ENTRY>\n"
        }
        out += "</PLAYLIST>\n</NODE>\n</SUBNODES>\n</NODE>\n</PLAYLISTS>\n<INDEXING></INDEXING>\n</NML>\n"
        return out
    }
}
