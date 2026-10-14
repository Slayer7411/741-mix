import Foundation

/// Name einer Set-Aufnahme: `JJJJ-MM-TT HH.MM Set.<ext>`, bei Konflikt ` 2`, ` 3` … (gilt für Audio, .txt und .cue)
public enum RecordingName {
    public static func stem(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d.%02d Set", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// freier Stamm: weder `<stamm>.<ext>` noch die Begleitdateien existieren
    public static func free(_ date: Date, ext: String, calendar: Calendar = .current, exists: (String) -> Bool) -> String {
        let base = stem(date, calendar: calendar)
        var n = 1
        while true {
            let s = n == 1 ? base : "\(base) \(n)"
            if ![ext, "txt", "cue"].contains(where: { exists("\(s).\($0)") }) { return s }
            n += 1
        }
    }
}

/// Tracklist einer Aufnahme aus der History: jeder Track, der während der Aufnahme gestartet wurde, mit Zeit ab
/// Aufnahmestart; Tracks, die beim Start schon liefen, stehen bei 0:00
public struct SetTracklist: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var offset: Double
        public var artist: String
        public var title: String
        public init(offset: Double, artist: String, title: String) { self.offset = offset; self.artist = artist; self.title = title }
    }

    /// History-Eintrag: Startzeit, Schlüssel, Artist, Titel
    public struct Played: Sendable {
        public var start: Date
        public var key: String
        public var artist: String
        public var title: String
        public init(start: Date, key: String, artist: String, title: String) {
            self.start = start; self.key = key; self.artist = artist; self.title = title
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries }

    /// `playingAtStart` = Schlüssel der Tracks, die beim Aufnahmestart liefen (ihr letzter Eintrag davor -> 0:00);
    /// `end` = Aufnahmeende (später gestartete fallen weg)
    public init(history: [Played], start: Date, end: Date? = nil, playingAtStart: Set<String> = []) {
        var list: [Entry] = []
        var before: [String: Played] = [:]
        for p in history {
            if p.start >= start {
                if let end, p.start > end { continue }
                list.append(Entry(offset: p.start.timeIntervalSince(start), artist: p.artist, title: p.title))
            } else if playingAtStart.contains(p.key), before[p.key].map({ $0.start < p.start }) ?? true {
                before[p.key] = p
            }
        }
        let early = before.values.sorted { $0.start < $1.start }.map { Entry(offset: 0, artist: $0.artist, title: $0.title) }
        entries = early + list.sorted { $0.offset < $1.offset }
    }

    /// `m:ss`, ab einer Stunde `h:mm:ss`; unter 10 Minuten zweistellig (`00:00`)
    public static func time(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// eine Zeile je Track: `00:00 Artist – Titel`
    public var text: String {
        entries.map { e in
            let who = e.artist.isEmpty ? e.title : e.title.isEmpty ? e.artist : "\(e.artist) – \(e.title)"
            return "\(Self.time(e.offset)) \(who)"
        }.joined(separator: "\n") + (entries.isEmpty ? "" : "\n")
    }

    /// CUE-Sheet zur Audiodatei `audioFile` (nur der Name), INDEX in mm:ss:ff (75 Frames je Sekunde)
    public func cue(audioFile: String, title: String, date: Date? = nil, calendar: Calendar = .current) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "'") + "\"" }
        let type = audioFile.lowercased().hasSuffix(".aif") || audioFile.lowercased().hasSuffix(".aiff") ? "AIFF" : "WAVE"
        var lines: [String] = []
        if let date {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            lines.append(String(format: "REM DATE %04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0))
        }
        lines.append("TITLE \(q(title))")
        lines.append("FILE \(q(audioFile)) \(type)")
        for (i, e) in entries.enumerated() {
            lines.append(String(format: "  TRACK %02d AUDIO", i + 1))
            lines.append("    TITLE \(q(e.title))")
            if !e.artist.isEmpty { lines.append("    PERFORMER \(q(e.artist))") }
            lines.append("    INDEX 01 \(Self.cueTime(e.offset))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// mm:ss:ff, Minuten ohne Obergrenze
    public static func cueTime(_ s: Double) -> String {
        let f = max(0, Int((s * 75).rounded(.down)))
        return String(format: "%02d:%02d:%02d", f / 75 / 60, f / 75 % 60, f % 75)
    }
}
