import Foundation
import MixEngine

/// Darstellung der Wellenform
enum WaveformStyle: String, CaseIterable, Codable, Identifiable {
    case threeBand = "3-Band (Schichten)", spectrum = "Spektrum (Traktor)", mono = "Einfarbig"
    var id: String { rawValue }
}

enum WaveformPalette: String, CaseIterable, Codable, Identifiable {
    case bone = "741 Knochen", orange = "Orange", blue = "Blau/Weiß", traktor = "Traktor"
    var id: String { rawValue }
}

/// Was die Cue-Taste am X1 macht
enum X1CueAction: String, CaseIterable, Codable, Identifiable {
    case fluxReverse = "Flux-Reverse (halten)", cue = "Cue (wie Traktor-Standard)", reverse = "Reverse (halten)"
    var id: String { rawValue }
}

enum X1StripMode: String, CaseIterable, Codable, Identifiable {
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

struct X1Prefs: Codable, Equatable {
    var cueAction = X1CueAction.fluxReverse
    /// Flux antippen schaltet Flux-Modus (gehalten = Beatjump-Ebene für Hotcue 3/4)
    var fluxTapToggles = true
    var fluxBeatjumpBeats = 1.0
    var stripMode = X1StripMode.bend
    var stripSensitivity = 1.0
    var browseFastStep = 10
    var ledOn = 127
    var ledOff = 5
    var cuePadColor = PadColor.red
    var loopPadColor = PadColor.green
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
    /// History zusätzlich in Traktors History-Ordner schreiben (dort im Archiv sichtbar)
    var historyToTraktor = false
    /// Trennzeichen für Tags in Kommentar 2 (jedes Zeichen trennt; Standard Leerzeichen)
    var tagSeparators = " "
    /// Beatgrid farbig (Phrasen/Takte/Beats) oder schlicht
    var colorfulGrid = true
    /// Beats je Phrase (Markierung/Farbwechsel)
    var phraseBeats = 64
}

/// Alle Einstellungen der App, als JSON in UserDefaults gespeichert.
struct AppPrefs: Codable, Equatable {
    var engine = EnginePrefs()
    var ui = UIPrefs()
    var x1 = X1Prefs()

    static let key = "prefs.v1"

    /// Lädt gespeicherte Einstellungen; fehlende (neue) Felder bekommen ihren Standardwert,
    /// statt dass alles auf Standard zurückfällt.
    static func load() -> AppPrefs {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppPrefs()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return AppPrefs() }
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var r = base
            for (k, v) in over {
                if let b = base[k] as? [String: Any], let o = v as? [String: Any] { r[k] = merge(b, o) } else if base[k] != nil { r[k] = v }
            }
            return r
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: merge(defaults, saved)),
              let p = try? JSONDecoder().decode(AppPrefs.self, from: merged) else { return AppPrefs() }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
