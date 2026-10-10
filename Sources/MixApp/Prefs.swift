import Foundation
import MixCore
import MixEngine

/// Darstellung der Wellenform
enum WaveformStyle: String, CaseIterable, Codable, Identifiable {
    case threeBand = "3-Band (Schichten)", spectrum = "Spektrum", mono = "Einfarbig"
    var id: String { rawValue }
}

enum WaveformPalette: String, CaseIterable, Codable, Identifiable {
    case bone = "741 Knochen", orange = "Orange", blue = "Blau/Weiß", classic = "Klassisch"
    var id: String { rawValue }
}

/// Was die Cue-Taste am Controller macht
enum ControllerCueAction: String, CaseIterable, Codable, Identifiable {
    case fluxReverse = "Flux-Reverse (halten)", cue = "Cue (Standard)", reverse = "Reverse (halten)"
    var id: String { rawValue }
}

/// Flux gehalten + Pads: zweite Hotcue-Reihe oder Beatjump auf Pad 3/4
enum ControllerFluxPads: String, CaseIterable, Codable, Identifiable {
    case hotcues = "Hotcues 5–8", beatjump = "Beatjump (Pads 3/4)"
    var id: String { rawValue }
}

enum ControllerStripMode: String, CaseIterable, Codable, Identifiable {
    case bend = "Pitch-Bend (Shift: Suchen)", seek = "Suchen (Shift: Pitch-Bend)"
    var id: String { rawValue }
}

enum PadColor: String, CaseIterable, Codable, Identifiable {
    case red = "Rot", blue = "Blau", orange = "Orange", white = "Weiß", green = "Grün", magenta = "Magenta"
    var id: String { rawValue }
    var rgb: (r: UInt8, g: UInt8, b: UInt8) {
        switch self {
        case .red: (0x7f, 0, 0)
        case .blue: (0, 0x10, 0x7f)
        case .orange: (0x7f, 0x28, 0)
        case .white: (0x7f, 0x7f, 0x7f)
        case .green: (0, 0x7f, 0)
        case .magenta: (0x7f, 0, 0x60)
        }
    }
}

struct ControllerPrefs: Codable, Equatable {
    var cueAction = ControllerCueAction.fluxReverse
    /// Flux antippen schaltet Flux-Modus (gehalten = Beatjump-Ebene für Hotcue 3/4)
    var fluxTapToggles = true
    var fluxBeatjumpBeats = 1.0
    var fluxPads = ControllerFluxPads.hotcues
    var stripMode = ControllerStripMode.bend
    var stripSensitivity = 1.0
    var browseFastStep = 10
    var ledOn = 127
    var ledOff = 5
    // alte Felder (nicht mehr benutzt, bleiben für gespeicherte Einstellungen)
    var cuePadColor = PadColor.red
    var loopPadColor = PadColor.green
    // Cue-Farben (Bildschirm + Controller-Pads)
    var colorStartCue = PadColor.red
    var colorCue = PadColor.white
    var colorLoop = PadColor.green
    var colorShortLoop = PadColor.magenta
    /// Loops bis zu so vielen Takten gelten als kurz (magenta)
    var shortLoopBars = 2.0

    /// Farbe eines Cues: Start-Cue (Load/AutoGrid), sonstige Cues, Loops, kurze Loops
    func color(for c: Cue, startMs: Double?, bpm: Double) -> PadColor {
        switch c.kind {
        case .loop:
            let bars = bpm > 0 ? c.lengthMs / 1000 / (60 / bpm) / 4 : 99
            return bars <= shortLoopBars + 0.01 ? colorShortLoop : colorLoop
        case .load, .grid:
            return colorStartCue
        default:
            if let s = startMs, abs(c.startMs - s) < 5 { return colorStartCue }
            return colorCue
        }
    }
}

struct UIPrefs: Codable, Equatable {
    var showMixer = true
    var showFourDecks = true
    var showFXUnits = true
    var waveformSeconds = 4.0
    var waveformStyle = WaveformStyle.threeBand
    var waveformPalette = WaveformPalette.bone
    var showBeatgrid = true
    var showBarNumbers = true
    var dimPlayed = true
    var waveformHeight = 60.0
    var previewStart = 0.3
    var browserHeight = 240.0
    var browserLayout = BrowserLayout.sideBySide
    /// Ordner-Baum ausblenden, solange die Decks zu sehen sind (Browser-Listen breiter)
    var hideTreeWithDecks = false
    var tagHighlight = true
    /// 2 oder 4 FX-Units
    var fxUnitCount = 2
    /// Marker alle 8 / 16 / 32 Takte in der Wellenform (magenta)
    var barMarkers = true
    /// "system", "de" oder "en" – wirkt nach Neustart
    var language = "system"
    /// Tag → Farbe (hex), sonst Standardfarbe aus dem Namen
    var tagColors: [String: String] = [:]
    /// Grid-Werkzeuge am Deck zeigen
    var showGridTools = true
    /// History zusätzlich in den History-Ordner der Collection schreiben (dort im Archiv sichtbar)
    var historyToExternal = false
    /// Trennzeichen für Tags in Kommentar 2 (jedes Zeichen trennt; Standard Leerzeichen)
    var tagSeparators = " "
    /// Beatgrid farbig (Phrasen/Takte/Beats) oder schlicht
    var colorfulGrid = true
    /// Beats je Phrase (Markierung/Farbwechsel)
    var phraseBeats = 64
    /// MUSIC FOLDERS: eigene Musik-Ordner (leer = automatisch aus der Collection)
    var musicFolders: [String] = []
}

/// Alle Einstellungen der App, als JSON in UserDefaults gespeichert.
struct AppPrefs: Codable, Equatable {
    var engine = EnginePrefs()
    var ui = UIPrefs()
    var controller = ControllerPrefs()

    static let key = "prefs.v1"

    /// Lädt gespeicherte Einstellungen; fehlende (neue) Felder bekommen ihren Standardwert,
    /// statt dass alles auf Standard zurückfällt.
    static func load() -> AppPrefs {
        guard let data = UserDefaults.standard.data(forKey: key),
              var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppPrefs()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return AppPrefs() }
        if let old = saved["x1"], saved["controller"] == nil { saved["controller"] = old }   // alter Schlüssel
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var r = base
            for (k, v) in over {
                if let b = base[k] as? [String: Any], let o = v as? [String: Any] { r[k] = merge(b, o) } else if base[k] != nil { r[k] = v }
            }
            return r
        }
        if let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, saved)),
           let p = try? JSONDecoder().decode(AppPrefs.self, from: merged) { return p }
        // einzelner Wert passt nicht mehr (z. B. nach Update) → Wert für Wert übernehmen, Rest bleibt erhalten
        func leaves(_ d: [String: Any], _ path: [String] = []) -> [([String], Any)] {
            d.flatMap { k, v -> [([String], Any)] in
                if let o = v as? [String: Any] { return leaves(o, path + [k]) }
                return [(path + [k], v)]
            }
        }
        func setting(_ d: [String: Any], _ path: [String], _ v: Any) -> [String: Any] {
            var r = d
            guard let k = path.first else { return r }
            if path.count == 1 { if r[k] != nil { r[k] = v } } else if let sub = r[k] as? [String: Any] { r[k] = setting(sub, Array(path.dropFirst()), v) }
            return r
        }
        var good = defaults
        for (path, v) in leaves(saved) {
            let trial = setting(good, path, v)
            if let data = try? JSONSerialization.data(withJSONObject: trial), (try? JSONDecoder().decode(AppPrefs.self, from: data)) != nil {
                good = trial
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: good),
              let p = try? JSONDecoder().decode(AppPrefs.self, from: data) else { return AppPrefs() }
        return p
    }

    func save() {
        guard !Session.isSelfTest else { return }   // Selbsttest darf Christians Einstellungen nicht überschreiben
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
