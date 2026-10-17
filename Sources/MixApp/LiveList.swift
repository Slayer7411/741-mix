import AppKit

/// Schnitt der Schrift in der Live-Liste
enum LiveListWeight: String, CaseIterable, Codable, Identifiable {
    case regular = "Regular", medium = "Medium", semibold = "SemiBold"
    var id: String { rawValue }
    var fontName: String { "IBMPlexMono-\(rawValue)" }
}

/// Live-Lesbarkeit der Track-Liste (⌘, -> BROWSER, Abschnitt „Live-Lesbarkeit“; automatisch bei LIVE): feste Spalten
/// Artist, Title, BPM, Key, Time mit ✓ für gespielte Tracks vorn, Schrift unabhängig vom Zoom, alles knochenweiß,
/// Zeilen mit Trennlinie, ausgewählte Zeile invertiert. Die normale Spaltenanordnung bleibt gespeichert und kommt
/// beim Ende des Modus wieder (im Modus wird nichts gespeichert).
@MainActor
enum LiveList {
    /// Spalten in Reihenfolge (played = Markerspalte am Zeilenanfang: alle Zustände, siehe TrackTableController.liveMarkers)
    static let columns = ["played", "artist", "title", "bpm", "key", "time"]
    static let sizeRange: ClosedRange<Double> = 11...18
    /// Zeilenhöhe je pt Schrift
    static let lineFactor: CGFloat = 1.6
    /// Hintergrund abwechselnder Zeilen (sehr leicht auf Void)
    static let stripeFill = NSColor(Theme.bone).withAlphaComponent(0.045)
    /// Trennlinie unter jeder Zeile (kräftiger als im normalen Modus)
    static let separator = NSColor(Theme.muted).withAlphaComponent(0.5)

    static func clampSize(_ v: Double) -> CGFloat { CGFloat(min(max(v, sizeRange.lowerBound), sizeRange.upperBound)) }

    /// Zeilenhöhe in pt (ohne Zoom)
    static func rowHeight(_ size: CGFloat) -> CGFloat { (size * lineFactor).rounded() }

    /// Breite einer Stelle: IBM Plex Mono hat 0,6 em
    static func advance(_ size: CGFloat) -> CGFloat { size * 0.6 }

    /// Platz je Zustand in der Markerspalte (gespielt, Datei, analysiert, Rip-Befund)
    static func markerSlot(_ size: CGFloat) -> CGFloat { (advance(size) + 4).rounded(.up) }

    static func font(_ size: CGFloat, _ w: LiveListWeight) -> NSFont {
        NSFont(name: w.fontName, size: size) ?? TableStyle.mono(size)
    }

    /// Schlüssel der gespeicherten Anordnung der normalen Liste; im Live-Modus nil (nichts lesen, nichts schreiben)
    static func storageKey(name: String, twoText: Bool, live: Bool) -> String? {
        live ? nil : "columns.\(name)" + (twoText ? ".2" : "")
    }

    /// Breiten einer Spalte der Live-Liste in pt ohne Zoom: min = max = feste Breite, sonst flexibel (Title füllt den Rest)
    static func width(_ id: String, size s: CGFloat) -> (min: CGFloat, ideal: CGFloat, max: CGFloat) {
        let a = advance(s), b = advance(s + 1)
        switch id {
        case "played": let w = (4 * markerSlot(s) + 6).rounded(.up); return (w, w, w)
        case "bpm": let w = (6 * b + 10).rounded(.up); return (w, w, w)
        case "key": let w = ((s * 0.95).rounded() + 3 * b + 10).rounded(.up); return (w, w, w)
        case "time": let w = (5 * a + 10).rounded(.up); return (w, w, w)
        case "title": return (14 * a, 34 * a, .greatestFiniteMagnitude)
        default: return (12 * a, 24 * a, 28 * a)   // Artist: nicht breiter als nötig, Title bekommt den Rest
        }
    }
}

extension UIPrefs {
    /// Live-Liste jetzt: von Hand eingeschaltet, oder automatisch solange LIVE an ist
    func liveListOn(live: Bool) -> Bool { liveList || (liveListAuto && live) }
}
