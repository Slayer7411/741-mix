import SwiftUI
import MixCore
import MixEngine

/// CI-741: Void/Chitin-Schwarz, Knochenweiß, Rot nur als Zustand, Cinzel versal für Labels,
/// IBM Plex Mono für Daten, Radius 0, 1-px-Haarlinien, Unicode statt Icons.
enum Theme {
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    static let void = rgb(10, 9, 8)
    static let chitin = rgb(19, 17, 15)
    static let chitinRaised = rgb(27, 24, 21)
    static let hairline = rgb(52, 46, 41)
    static let bone = rgb(230, 225, 218)
    static let muted = rgb(111, 100, 92)
    /// 741-Rot – nur für Zustände (an, spielt, aktiv)
    static let state = rgb(210, 31, 38)
    /// Lila – zweiter Zustand (Master)
    static let secondary = rgb(150, 70, 210)

    /// Gold – Rahmen des Master-Decks
    static let gold = rgb(212, 175, 55)
    static let accent = bone
    static let background = void
    static let deck = chitin
    static let deckFocused = chitinRaised
    static let panelHeader = chitin
    static let wave = rgb(14, 12, 11)

    /// Cinzel versal – Titel und Labels
    static func label(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .custom("Cinzel", size: size).weight(w) }
    /// IBM Plex Mono – Daten (Zeiten, BPM, Titel, Listen)
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("IBM Plex Mono", size: size).weight(w) }

    /// Schriften aus dem App-Bundle registrieren (vor dem ersten Zeichnen)
    static func registerFonts() {
        guard let dir = AppResources.url("Fonts", nil) else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in urls where u.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
        }
    }

    /// Traktor-Farben 1–7 (rot, orange, gelb, grün, blau, violett, magenta)
    static func trackColor(_ c: Int) -> Color {
        switch c {
        case 1: .red
        case 2: .orange
        case 3: .yellow
        case 4: .green
        case 5: .blue
        case 6: .purple
        case 7: .pink
        default: .clear
        }
    }

    static func roleColor(_ r: RoleFilter) -> Color {
        switch r {
        case .basis: .orange
        case .synth: .cyan
        case .drums: .red
        case .voll: .purple
        case .atmo: .teal
        }
    }

    /// Cue-Farbe mit Einstellungen (Cue/Loop-Farbe wählbar, Standard: Cue rot)
    /// Cue-Farbe nach Rolle (Start-Cue, Cue, Loop, kurzer Loop) – einstellbar unter ⌘, → Anzeige
    static func cueColor(_ c: Cue, deck: DeckState, prefs: AppPrefs) -> Color {
        color(prefs.x1.color(for: c, startMs: startCueMs(deck.track), bpm: deck.grid?.bpm ?? deck.track?.bpm ?? 0))
    }

    /// Start-Cue eines Tracks: Load-Cue, sonst AutoGrid
    static func startCueMs(_ t: Track?) -> Double? {
        guard let t else { return nil }
        return t.cues.first { $0.kind == .load }?.startMs ?? t.gridAnchorMs
    }

    static func color(_ p: PadColor) -> Color {
        let c = p.rgb
        return Color(red: Double(c.r) / 127, green: Double(c.g) / 127, blue: Double(c.b) / 127)
    }

    static func cueColor(_ k: Cue.Kind) -> Color {
        switch k {
        case .cue: .red          // Christian: Cues rot statt Traktor-blau
        case .fadeIn, .fadeOut: .pink
        case .load: .yellow
        case .grid: .white
        case .loop: .green
        }
    }

    /// Tonart-Farbe nach Quintenzirkel (wie Traktors Key-Farben).
    static func keyColor(_ k: Int) -> Color {
        guard k >= 0 else { return .secondary }
        let pos = ((k < 12 ? k % 12 : k % 12 + 3) * 7) % 12
        return Color(hue: Double(pos) / 12, saturation: 0.55, brightness: 0.95)
    }

    static func time(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ d: Date) -> String { dateFormat.string(from: d) }

    static let dateTimeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
