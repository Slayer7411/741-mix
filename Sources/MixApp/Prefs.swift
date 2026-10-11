import Foundation
import MixCore
import MixEngine

/// Darstellung der Wellenform
enum WaveformStyle: String, CaseIterable, Codable, Identifiable {
    case threeBand = "3-Band (Schichten)", spectrum = "Spektrum", mono = "Einfarbig"
    var id: String { rawValue }
}

/// Spektrum-Stil: fein (6 Bänder, eigene Farben, Höhen zusätzlich als Ebene darüber), fein nur gemischt, oder einfach (3 Bänder, Palette)
enum SpectrumDetail: String, CaseIterable, Codable, Identifiable {
    case fine = "Spektrum fein (6 Bänder)", fineMix = "Spektrum fein, ohne Höhen-Ebene", simple = "Spektrum (3 Bänder)"
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

/// Was die Flux-Taste am Controller macht: Pad-Ebene umschalten (Hotcues 5–8, Shift + Flux = Flux-Modus) oder Flux-Modus
enum ControllerFluxButton: String, CaseIterable, Codable, Identifiable {
    case padLayer = "Pad-Ebene umschalten (Hotcues 5–8)", fluxMode = "Flux-Modus"
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
    var fluxButton = ControllerFluxButton.padLayer
    /// nur im Flux-Modus: Flux antippen schaltet Flux-Modus (gehalten = Pad-Ebene)
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

/// Sichtbare Zeilen je Deck; alles an = bisheriges Bild. Neue Felder: gespeicherte Einstellungen ohne sie bekommen
/// den Standard (AppPrefs.decode legt die gespeicherten Werte über die Standardwerte)
struct DeckRows: Codable, Equatable {
    /// Kopf rechts: Zeit, BPM/Tempo, Code, Key + Phase
    var info = true
    /// Kopf, Zeile unter dem Titel: Kommentar (gedämpft) …
    var comment = true
    /// … und Tags aus Kommentar 2 als Chips
    var tags = true
    var phaseBar = true
    var overview = true
    var transport = true
    /// Hotcues mit IN / OUT / RE
    var hotcues = true
    var loop = true
    var jump = true
    /// Pitch-Fader rechts
    var tempo = true

    /// Reihenfolge für Menü und Einstellungen: wie im Deck von oben nach unten, Pitch-Fader zuletzt.
    /// Grid-Werkzeuge liegen (älter) in UIPrefs, deshalb Pfade ab UIPrefs
    static let all: [(WritableKeyPath<UIPrefs, Bool>, String)] = [
        (\.deckRows.info, "Zusatzinfos (Zeit, BPM, Code, Key)"), (\.deckRows.comment, "Kommentar"),
        (\.deckRows.tags, "Tags (Kommentar 2)"), (\.deckRows.phaseBar, "Phasenbalken"), (\.deckRows.overview, "Übersicht"),
        (\.deckRows.transport, "Transport (CUE, PLAY, SYNC …)"), (\.deckRows.hotcues, "Hotcues (mit IN / OUT / RE)"),
        (\.deckRows.loop, "Loop-Größen"), (\.deckRows.jump, "Beatjump"), (\.showGridTools, "Grid-Werkzeuge"),
        (\.deckRows.tempo, "Pitch-Fader"),
    ]
}

struct UIPrefs: Codable, Equatable {
    var showMixer = true
    var showFourDecks = true
    var showFXUnits = true
    var waveformSeconds = 4.0
    var waveformStyle = WaveformStyle.threeBand
    var waveformPalette = WaveformPalette.bone
    /// Spektrum-Stil: feine 6-Band-Farben oder die alten 3 Bänder
    var spectrumDetail = SpectrumDetail.fine
    /// Höhen-Betonung (0 = neutral, 1 = Standard, 2 = stark): feines Spektrum 0…10 dB, 3-Band Höhen-Gewicht ×0,5…×2
    var waveformHighBoost = 1.0
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
    /// Zeilen des Decks einzeln ein-/ausblenden (Menü DECKS -> Zeilen, ⌘, -> Decks)
    var deckRows = DeckRows()
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
    /// Metadaten-Änderungen aus dem Browser auch in die Collection-Datei schreiben (mit Sicherung davor)
    var writeCollection = false
    /// Browser-Vorschau (Mini-Wellenform + Grid + Cues): ganze Zeile (zweizeilig), eigene Spalte, hinter dem Titel oder aus
    var previewMode = PreviewMode.fullRow
    /// Farben der Vorschau: Spektrum (rot/grün/blau) oder wie die Wellenform
    var previewColors = PreviewColors.spectrum
    /// alt (bis 0.x): Hintergrund an/aus – nur noch für die Umstellung auf `previewFill`
    var previewBackground = true
    /// fehlende Vorschauen im Hintergrund berechnen: immer (gedrosselt, solange ein Deck spielt) / nur ohne Deck / aus
    var previewFill = PreviewFill.always
    /// Vorschau „ganze Zeile“: Schriftgröße der Textzeile (pt) und ob halbfett
    var previewTextSize = 12.0
    var previewTextBold = true
    /// Vorschau „ganze Zeile“: Deckkraft des Bandes (1 = voll, kleiner = gedämpft, Text hebt sich ab)
    var previewBandAlpha = 0.75
    /// Cover links im Deck-Kopf
    var showDeckCover = true
    /// Cover des gewählten Tracks unter dem Baum im Browser
    var showCoverPreview = true
    /// Last-Anzeigen rechts in der Statusleiste (DSP, Latenz, Aussetzer, Speicher, CPU)
    var showMeters = true
    /// Collection prüfen: beim Start nach dem Laden automatisch
    var checkOnStart = false
    /// Collection prüfen: Musik-Ordner nach Dateien ohne Collection-Eintrag durchsuchen
    var checkMusicFolders = true
    /// Zoom des Hauptfensters (1 = 100 %, ZoomSteps)
    var zoom = 1.0
    /// eigene Analyse: BPM-Bereich genau eine Oktave, Untergrenze (Obergrenze = 2 ×)
    var analysisBpmLow = 100.0

    /// kompakte Decks: ohne Pitch-Fader, Hotcues und Grid-Werkzeuge (mehr Platz für Wellenform und Beatgrid)
    var compactDecks: Bool {
        get { !deckRows.tempo && !deckRows.hotcues && !showGridTools }
        set { deckRows.tempo = !newValue; deckRows.hotcues = !newValue; showGridTools = !newValue }
    }

    /// alle Zeilen aus DeckRows.all an
    mutating func showAllDeckRows() { for (k, _) in DeckRows.all { self[keyPath: k] = true } }

    /// EDIT-Modus je Deck A–D (Schnitt + Grid statt Loop / Beatjump), Standard aus
    var editDecks = [false, false, false, false]

    func editing(_ d: Int) -> Bool { editDecks.indices.contains(d) && editDecks[d] }
    mutating func setEditing(_ d: Int, _ on: Bool) {
        guard d >= 0, d < 4 else { return }
        while editDecks.count < 4 { editDecks.append(false) }
        editDecks[d] = on
    }
}

/// Alle Einstellungen der App, als JSON in UserDefaults gespeichert.
struct AppPrefs: Codable, Equatable {
    var engine = EnginePrefs()
    var ui = UIPrefs()
    var controller = ControllerPrefs()
    /// Cloud-Library: lokal halten, Downloads (⌘, -> CLOUD)
    var cloud = CloudPrefs()
    /// eigene Tastenkürzel: Aktion-ID -> Kombination als Text ("" = frei), sonst Standard (ShortcutID.defaultCombo)
    var shortcuts: [String: String] = [:]

    var keys: ShortcutMap {
        get { ShortcutMap(overrides: shortcuts) }
        set { shortcuts = newValue.overrides }
    }

    static let key = "prefs.v1"

    /// Lädt gespeicherte Einstellungen; fehlende (neue) Felder bekommen ihren Standardwert,
    /// statt dass alles auf Standard zurückfällt.
    static func load() -> AppPrefs {
        var p = loadSaved()
        // FDN-Hall: neue Standard-Helligkeit 0,6; wer den alten Standard 0,4 nie verändert hat, bekommt den neuen (einmalig)
        let d = UserDefaults.standard
        if !Session.isSelfTest, !d.bool(forKey: "migrated.reverb-fdn") {
            if d.data(forKey: key) != nil, p.engine.reverbBrightness == 0.4 { p.engine.reverbBrightness = EnginePrefs().reverbBrightness; p.save() }
            d.set(true, forKey: "migrated.reverb-fdn")
        }
        // Browser-Vorschau: alter Standard „eigene Spalte“ -> neuer Standard „ganze Zeile“ (einmalig)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.preview-row") {
            if d.data(forKey: key) != nil, p.ui.previewMode == .column { p.ui.previewMode = .fullRow; p.save() }
            d.set(true, forKey: "migrated.preview-row")
        }
        // Hintergrund-Vorschauen: wer den alten Schalter ausgeschaltet hatte, bekommt „aus“ (einmalig)
        if !Session.isSelfTest, !d.bool(forKey: "migrated.preview-fill") {
            if d.data(forKey: key) != nil, !p.ui.previewBackground { p.ui.previewFill = .off; p.save() }
            d.set(true, forKey: "migrated.preview-fill")
        }
        return p
    }

    private static func loadSaved() -> AppPrefs {
        guard let data = UserDefaults.standard.data(forKey: key) else { return AppPrefs() }
        return decode(data)
    }

    /// gespeichertes JSON über die Standardwerte legen: fehlende (neue) Felder bekommen ihren Standard
    static func decode(_ data: Data) -> AppPrefs {
        guard var saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppPrefs()),
              let defaults = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return AppPrefs() }
        if let old = saved["x1"], saved["controller"] == nil { saved["controller"] = old }   // alter Schlüssel
        func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
            var r = base
            for (k, v) in over {
                // leeres Objekt im Standard = freie Zuordnung (tagColors, shortcuts) -> gespeicherten Inhalt ganz übernehmen
                if let b = base[k] as? [String: Any], !b.isEmpty, let o = v as? [String: Any] { r[k] = merge(b, o) } else if base[k] != nil { r[k] = v }
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
