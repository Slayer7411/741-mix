import Foundation

/// Ein Suchtreffer bei TIDAL
struct TidalCandidate: Equatable, Sendable {
    var id: String
    var title: String
    var artist: String
    /// Sekunden, 0 = unbekannt
    var duration: Double
}

/// Zuordnung Collection -> TIDAL, rein und ohne Netz: Suchtext, Treffer-Prüfung, Playlist-Name
enum TidalMatch {
    /// Abweichung der Dauer in Sekunden, ab der ein Treffer nicht passt (nur wenn beide Dauern bekannt sind)
    static let durationTolerance = 5.0
    /// Muster des Playlist-Namens: %Y Jahr, %y zwei Stellen, %m Monat, %d Tag
    static let defaultPattern = "missing-%y%m%d"

    /// Vergleichsform: klein, ohne Akzente, ß -> ss, alles außer Buchstaben und Ziffern -> Leerzeichen
    static func fold(_ s: String) -> String {
        let f = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ß", with: "ss")
        return String(f.map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    /// Titel ohne Zusätze: Klammergruppen („(Original Mix)“, „[Remastered]“) und ein Suffix „ - Radio Edit“ fallen weg
    static func baseTitle(_ title: String) -> String {
        var t = title
        while let r = t.range(of: #"\s*[\(\[][^\(\)\[\]]*[\)\]]"#, options: .regularExpression) {
            t.removeSubrange(r)
        }
        if let r = t.range(of: " - ", options: .backwards) {
            let tail = fold(String(t[r.upperBound...])).split(separator: " ").map(String.init)
            if tail.contains(where: { versionWords.contains($0) }) { t = String(t[..<r.lowerBound]) }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static let versionWords: Set<String> = [
        "mix", "edit", "remaster", "remastered", "version", "remix", "radio", "extended", "original", "mono",
        "stereo", "live", "club", "dub", "instrumental", "vip", "rework", "bonus", "deluxe",
    ]

    /// Künstler passen: gleiche Vergleichsform, oder der kürzere steht als ganze Wörter im längeren („A feat. B“, „A & B“)
    static func artistMatches(_ local: String, _ remote: String) -> Bool {
        let a = fold(local), b = fold(remote)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        return s.count >= 3 && (" " + l + " ").contains(" " + s + " ")
    }

    /// Treffer passt: Titel ohne Zusätze gleich, Künstler passt, Dauer innerhalb der Toleranz (wenn beide bekannt)
    static func passes(title: String, artist: String, duration: Double, _ c: TidalCandidate) -> Bool {
        let t = fold(baseTitle(title))
        guard !t.isEmpty, t == fold(baseTitle(c.title)) else { return false }
        guard artistMatches(artist, c.artist) else { return false }
        if duration > 0, c.duration > 0, abs(duration - c.duration) > durationTolerance { return false }
        return true
    }

    /// erster passender Treffer in der Rangfolge der Suche
    static func best(title: String, artist: String, duration: Double, _ cands: [TidalCandidate]) -> TidalCandidate? {
        cands.first { passes(title: title, artist: artist, duration: duration, $0) }
    }

    /// Suchtext „Artist Titel“, ohne Zusätze am Titel
    static func query(artist: String, title: String) -> String {
        [artist, baseTitle(title)].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Playlist-Name aus dem Muster; leeres Muster = Standard
    static func playlistName(pattern: String, year: Int, month: Int, day: Int) -> String {
        let p = pattern.trimmingCharacters(in: .whitespaces).isEmpty ? defaultPattern : pattern
        return p
            .replacingOccurrences(of: "%Y", with: String(format: "%04d", year))
            .replacingOccurrences(of: "%y", with: String(format: "%02d", year % 100))
            .replacingOccurrences(of: "%m", with: String(format: "%02d", month))
            .replacingOccurrences(of: "%d", with: String(format: "%02d", day))
    }

    static func playlistName(pattern: String, on date: Date = Date(), calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return playlistName(pattern: pattern, year: c.year ?? 2000, month: c.month ?? 1, day: c.day ?? 1)
    }
}
