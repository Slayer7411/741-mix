import Foundation

/// Audio-Edit-Editor: Samples <-> Sekunden, Anzeige (Zoom, Ansicht), Eingabe der Zeit, Zwischenablage
public enum AudioEditView {
    /// Zoom-Schritt je Tastendruck / Rad-Raste
    public static let zoomStep = 1.5
    /// feinste Ansicht: so viele Punkte je Sample (Sample-Ebene)
    public static let pointsPerSample = 16.0

    /// Sample am Zeitpunkt t (gerundet)
    public static func sample(_ t: Double, rate: Double) -> Int { Int((t * rate).rounded()) }

    /// Zeit des Samples n
    public static func time(_ n: Int, rate: Double) -> Double { Double(n) / rate }

    /// t auf das nächste Sample gerastet
    public static func aligned(_ t: Double, rate: Double) -> Double { time(sample(t, rate: rate), rate: rate) }

    /// Auswahl in Samples: Anfang, Ende, Länge
    public static func samples(_ r: TrackRange, rate: Double) -> (start: Int, end: Int, length: Int) {
        let a = sample(r.start, rate: rate), b = sample(r.end, rate: rate)
        return (a, b, max(0, b - a))
    }

    /// „m:ss.mmm“ (Minuten ohne Füllung)
    public static func clock(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%d:%02d.%03d", ms / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    /// Eingabe „m:ss.mmm“, „m:ss“, „ss,mmm“ oder Sekunden; nil = ungültig oder negativ
    public static func parse(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        let secs: Double?
        switch parts.count {
        case 1: secs = Double(parts[0])
        case 2:
            guard let m = Double(parts[0]), let r = Double(parts[1]), m >= 0, r >= 0 else { return nil }
            secs = m * 60 + r
        default: secs = nil
        }
        guard let v = secs, v.isFinite, v >= 0 else { return nil }
        return v
    }

    /// Zoom-Grenzen: feinste Ansicht (Sample-Ebene), gröbste = ganze Datei passt in `width`
    public static func secPerPointRange(duration: Double, width: Double, rate: Double) -> ClosedRange<Double> {
        let fine = 1 / (rate * pointsPerSample)
        let coarse = max(fine, duration / max(1, width))
        return fine...max(fine, coarse)
    }

    /// Ansicht in den Grenzen halten: Zoom im Bereich, Anfang so, dass die Datei nicht über den Rand scrollt
    public static func clamp(secPerPoint s: Double, start: Double, width: Double, duration: Double, rate: Double) -> (secPerPoint: Double, start: Double) {
        let r = secPerPointRange(duration: duration, width: width, rate: rate)
        let z = min(max(s, r.lowerBound), r.upperBound)
        let visible = z * width
        let lo = 0.0, hi = max(0, duration - visible)
        return (z, min(max(start, lo), hi))
    }

    /// Zoom um den Punkt `t` (liegt bei Punkt `x`): Faktor > 1 = hinein
    public static func zoom(secPerPoint s: Double, start: Double, by factor: Double, at t: Double, x: Double,
                            width: Double, duration: Double, rate: Double) -> (secPerPoint: Double, start: Double) {
        let z = s / factor
        return clamp(secPerPoint: z, start: t - x * z, width: width, duration: duration, rate: rate)
    }

    /// Ganze Datei in der Breite
    public static func fit(duration: Double, width: Double, rate: Double) -> (secPerPoint: Double, start: Double) {
        clamp(secPerPoint: duration / max(1, width), start: 0, width: width, duration: duration, rate: rate)
    }

    /// Auswahl füllt die Breite (mit kleinem Rand links und rechts)
    public static func fit(_ r: TrackRange, width: Double, duration: Double, rate: Double) -> (secPerPoint: Double, start: Double) {
        let len = max(r.length, 1 / rate)
        let z = len / max(1, width * 0.9)
        return clamp(secPerPoint: z, start: r.start - width * 0.05 * z, width: width, duration: duration, rate: rate)
    }

    /// Punkt-Position einer Zeit in der Ansicht und zurück
    public static func x(_ t: Double, start: Double, secPerPoint s: Double) -> Double { (t - start) / s }
    public static func time(x: Double, start: Double, secPerPoint s: Double) -> Double { start + x * s }

    /// Schrittweite der Zeitlinie: kleinster „runder“ Schritt, der mindestens `minPoints` Punkte Abstand hat
    public static func tickStep(secPerPoint s: Double, minPoints: Double = 90) -> Double {
        let steps: [Double] = [0.000_1, 0.000_2, 0.000_5, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5,
                               1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        return steps.first { $0 / s >= minPoints } ?? steps.last!
    }

    /// Frames, die die Ansicht zeigt (Ende ausgeschlossen, begrenzt auf `frames`)
    public static func visibleSamples(start: Double, secPerPoint s: Double, width: Double, rate: Double, frames: Int) -> Range<Int> {
        let a = max(0, sample(start, rate: rate)), b = min(frames, sample(start + width * s, rate: rate) + 1)
        return a..<max(a, b)
    }
}

/// Zwischenablage des Editors: Stücke eines Tracks. Einfügen nur in denselben Track (Quelle = Schlüssel)
public struct AudioEditClip: Equatable, Sendable {
    public let key: String
    public let segments: [EditSegment]

    public init(key: String, segments: [EditSegment]) {
        self.key = key
        self.segments = segments
    }

    public var length: Double { segments.reduce(0) { $0 + $1.length } }
}

/// Marke (oder Bereich) des Editors. Zeiten in Quellsekunden, damit sie beim Schneiden an derselben Stelle des Audios bleiben
public struct AudioMarker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var start: Double
    /// Ende des Bereichs (Quellsekunden); nil = Marke
    public var end: Double?

    public init(id: UUID = UUID(), name: String, start: Double, end: Double? = nil) {
        self.id = id
        self.name = name
        self.start = start
        self.end = end
    }
}

/// Marken je Track (Schlüssel -> Liste) in einer eigenen Datei neben edits.json, nie in der Collection.
/// Schreiben auf einer Hintergrund-Queue; `url` nil = nur im Speicher (Selbsttest, Tests)
public final class AudioMarkStore: @unchecked Sendable {
    private var marks: [String: [AudioMarker]]
    let url: URL?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "minos741.audiomarks", qos: .utility)

    public init(url: URL?) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let m = try? JSONDecoder().decode([String: [AudioMarker]].self, from: d) {
            marks = m
        } else {
            marks = [:]
        }
    }

    public func markers(_ key: String) -> [AudioMarker] { lock.lock(); defer { lock.unlock() }; return marks[key] ?? [] }

    /// Liste des Tracks ersetzen (leer = Eintrag entfernen)
    public func set(_ list: [AudioMarker], for key: String) {
        lock.lock()
        marks[key] = list.isEmpty ? nil : list
        lock.unlock()
        save()
    }

    private func save() {
        guard let url else { return }
        lock.lock()
        let snapshot = marks
        lock.unlock()
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            if let d = try? enc.encode(snapshot) { try? d.write(to: url, options: .atomic) }
        }
    }

    /// wartet, bis alle Schreibvorgänge durch sind (Tests, Beenden)
    public func flush() { queue.sync {} }
}
