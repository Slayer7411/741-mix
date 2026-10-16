import Foundation

/// Wellenform greifen (⌘, -> DECKS): Ziehen in der Wellenform wie am Teller. aus = nur suchen (wie bisher)
enum WaveGrab: String, CaseIterable, Codable, Identifiable {
    case off = "aus", vinyl = "Vinyl", jog = "Jog"
    var id: String { rawValue }
}

/// Ziehen → Spielverhalten, ohne Zustand (Tests: WaveGrabTests)
enum WaveGrabMath {
    /// Sekunden je Punkt: die Wellenform zeigt 2 × `span` Sekunden über die Breite (Zoom steckt in `span`)
    static func secPerPt(span: Double, width: Double) -> Double { span * 2 / max(1, width) }

    /// Verschiebung der Position für einen Zug um `dragPx` (nach rechts positiv). Der Inhalt folgt der Hand,
    /// also rückwärts in der Zeit: nach rechts = Position wird kleiner
    static func seconds(dragPx: Double, span: Double, width: Double) -> Double {
        -dragPx * secPerPt(span: span, width: width)
    }

    /// Vorwärts-Geschwindigkeit der Hand in Track-Sekunden je reale Sekunde (nach links = vorwärts), auf ±1 begrenzt
    static func speed(dragPx: Double, dt: Double, span: Double, width: Double) -> Double {
        guard dt > 0 else { return 0 }
        return max(-1, min(1, seconds(dragPx: dragPx, span: span, width: width) / dt))
    }

    /// Jog-Nudge: Pitch-Bend −1…1 aus der Hand-Geschwindigkeit (vorwärts = schneller; × Bend-Stärke der Einstellung)
    static func bend(speed: Double) -> Double { max(-1, min(1, speed)) }
}
