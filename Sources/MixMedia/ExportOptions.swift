import AVFoundation
import Foundation
import MixCore

/// Ausgabe-Einstellungen eines Renders (⌘, -> AUDIO-EDIT, Fenster EXPORT). `standard` = bisheriges Verhalten
public enum ExportContainer: String, CaseIterable, Codable, Sendable {
    /// wie Quelle: WAV / AIFF bleiben (Vorbereiten), sonst Apple Lossless
    case source, wav, aiff, alac, aac
}

public enum ExportBits: String, CaseIterable, Codable, Sendable {
    /// wie bisher: 16 bei 16-Bit-Quellen, sonst 24; WAV / AIFF in Quell-Bit-Tiefe
    case source, b16, b24, float32
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public var container = ExportContainer.source
    public var bits = ExportBits.source
    /// Abtastrate in Hz, 0 = wie Quelle
    public var rate = 0
    /// TPDF-Dither beim Schritt auf 16 Bit (Abtastrate gewandelt oder Quelle mit mehr Bit)
    public var dither = true
    /// AAC-Bitrate in kbit/s
    public var aacKbps = 256
    /// Dateiname: leer = Regel wie bisher; sonst {name} (Quelle) und {tag} (Kennung des Jobs) ersetzt
    public var pattern = ""

    public static let standard = ExportOptions()
    public static let rates = [0, 44100, 48000, 88200, 96000]
    public static let aacRates = [128, 192, 256, 320]

    public init() {}

    /// Felder fehlen in älteren Einstellungen -> Standard
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        container = (try? c.decodeIfPresent(ExportContainer.self, forKey: .container)) ?? .source
        bits = (try? c.decodeIfPresent(ExportBits.self, forKey: .bits)) ?? .source
        rate = (try? c.decodeIfPresent(Int.self, forKey: .rate)) ?? 0
        dither = (try? c.decodeIfPresent(Bool.self, forKey: .dither)) ?? true
        aacKbps = (try? c.decodeIfPresent(Int.self, forKey: .aacKbps)) ?? 256
        pattern = (try? c.decodeIfPresent(String.self, forKey: .pattern)) ?? ""
    }

    enum CodingKeys: String, CodingKey { case container, bits, rate, dither, aacKbps, pattern }

    /// Dateiname (ohne Ordner): mit Muster `pattern` oder, leer, `fallback` (die Regel wie bisher). Belegt -> „ #2“ usw.
    public func fileName(original: String, tag: String, ext: String, taken: (String) -> Bool, fallback: () -> String) -> String {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return fallback() }
        let base = (original as NSString).deletingPathExtension
        var stem = p.replacingOccurrences(of: "{name}", with: base).replacingOccurrences(of: "{tag}", with: tag)
        stem = stem.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        stem = stem.trimmingCharacters(in: .whitespaces)
        guard !stem.isEmpty else { return fallback() }
        for n in 1...9999 {
            let name = (n == 1 ? stem : stem + " #\(n)") + "." + ext
            if !taken(name) { return name }
        }
        return stem + " " + UUID().uuidString.prefix(8) + "." + ext
    }
}

extension AudioCutWriter {
    /// Format einer neuen Datei nach den Einstellungen. `wavRule`: WAV / AIFF bleiben wie bisher (Vorbereiten); sonst
    /// Apple Lossless wie bisher (Schnitt, RENDER in AUDIO-EDIT / EDIT). Gültig nur: Float nur WAV, AIFF / ALAC 16 oder 24 Bit
    public static func format(matching url: URL, options o: ExportOptions, wavRule: Bool) -> Format {
        let srcBits = bitDepth(url: url)
        let base = wavRule ? format(matching: url) : .alac(srcBits)
        var f = base
        switch o.container {
        case .source: break
        case .wav: f = Format(container: .wav, bitDepth: base.bitDepth, float: base.float, ext: "wav")
        case .aiff: f = Format(container: .aiff, bitDepth: base.bitDepth, ext: "aiff")
        case .alac: f = .alac(base.bitDepth)
        case .aac: f = Format(container: .aac, bitDepth: 16, ext: "m4a", kbps: o.aacKbps)
        }
        switch o.bits {
        case .source: break
        case .b16: f.bitDepth = 16; f.float = false
        case .b24: f.bitDepth = 24; f.float = false
        case .float32: f.bitDepth = 32; f.float = true
        }
        if f.float, f.container != .wav { f.float = false; f.bitDepth = 24 }
        if f.container != .aac, !f.float, f.bitDepth != 16 { f.bitDepth = 24 }
        if f.float { f.bitDepth = 32 }
        f.rate = o.rate > 0 ? Double(o.rate) : nil
        // Dither nur beim Schritt auf 16 Bit: die Quelle hat mehr Bit, oder die Abtastrate wird gewandelt
        let reduces = srcBits > 16 || base.float || o.rate > 0
        f.dither = o.dither && f.container != .aac && !f.float && f.bitDepth == 16 && reduces
        return f
    }

}

/// Cover einer neuen Datei
public enum ExportCover: Equatable, Sendable {
    /// eingebettetes Bild der Quelle übernehmen (keins, wenn die Quelle keins hat)
    case keep
    case none
    case image(Data)
}

/// Metadaten einer neuen Datei: die Felder der Collection (Tonart als Open Key, 1d … 12m, BPM, Jahr)
public struct ExportTags: Equatable, Sendable {
    public var title = "", artist = "", album = "", remixer = "", label = "", genre = "", comment = "", key = ""
    public var year: Int?
    public var bpm: Double?
    public var cover = ExportCover.keep

    public init() {}

    public init(track t: Track) {
        title = t.title; artist = t.artist; album = t.album; remixer = t.remixer; label = t.label; genre = t.genre
        comment = t.comment; key = t.openKey
        year = t.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        bpm = t.bpm > 0 ? t.bpm : nil
    }

    /// Felder in den Track schreiben (Tonart: Open Key bzw. freier Text)
    public func apply(to t: inout Track) {
        t.title = title; t.artist = artist; t.album = album; t.remixer = remixer; t.label = label; t.genre = genre
        t.comment = comment
        t.bpm = bpm ?? 0
        if key != t.openKey {
            if let code = Self.musicalKey(openKey: key) { t.musicalKey = code; t.keyText = "" }
            else { t.musicalKey = -1; t.keyText = key }
        }
        let current = t.releaseDate.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
        if year != current {
            t.releaseDate = year.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 1, day: 1)) }
        }
    }

    /// MUSICAL_KEY (0–23) zu einem Open Key („8a“, „1d“ …); nil wenn der Text keiner ist. Umkehrung von `Track.openKey(code:)`
    public static func musicalKey(openKey s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard let last = t.last, last == "d" || last == "m", let n = Int(t.dropLast()), (1...12).contains(n) else { return nil }
        let y = ((n - 1) * 7) % 12   // Quintenzirkel-Position, bei Moll um drei Halbtöne verschoben
        let semitone = last == "m" ? (y + 9) % 12 : y
        return semitone + (last == "m" ? 12 : 0)
    }

    /// Cover-Bytes für die Datei: `.keep` liest das eingebettete Bild der Quelle
    public func coverData(source: URL?) -> Data? {
        switch cover {
        case .none: return nil
        case let .image(d): return d
        case .keep:
            guard let src = source else { return nil }
            if let d = ID3Chunk.picture(src) { return d }
            return try? MediaTags.embeddedCover(src)
        }
    }
}

/// Bildtyp eines Covers (für MIME und Metadaten)
public enum ArtImage {
    public static func mime(_ d: Data) -> String {
        d.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

/// Eingaben des Fensters EXPORT: `edited` sind die Felder, wie sie im Fenster stehen; `prefill` die Werte der Quelle.
/// Nur geänderte Felder überschreiben den Track (sonst bleibt, was der Job abgeleitet hat, z. B. „[cut]“ im Titel)
public struct ExportEdit: Sendable {
    public var options: ExportOptions
    public var edited: ExportTags
    public var prefill: ExportTags

    public init(options: ExportOptions, edited: ExportTags, prefill: ExportTags) {
        self.options = options; self.edited = edited; self.prefill = prefill
    }

    /// Track mit den geänderten Feldern aktualisieren; liefert die Metadaten für die Datei
    public func apply(to t: inout Track) -> ExportTags {
        var d = ExportTags(track: t)
        let e = edited, p = prefill
        if e.title != p.title { d.title = e.title }
        if e.artist != p.artist { d.artist = e.artist }
        if e.album != p.album { d.album = e.album }
        if e.remixer != p.remixer { d.remixer = e.remixer }
        if e.label != p.label { d.label = e.label }
        if e.genre != p.genre { d.genre = e.genre }
        if e.comment != p.comment { d.comment = e.comment }
        if e.key != p.key { d.key = e.key }
        if e.year != p.year { d.year = e.year }
        if e.bpm != p.bpm { d.bpm = e.bpm }
        d.cover = e.cover
        d.apply(to: &t)
        t.buildSearchText()
        return d
    }
}
