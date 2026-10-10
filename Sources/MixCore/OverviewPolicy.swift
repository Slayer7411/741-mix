import Foundation

/// Regeln der Vorschau-Berechnung (reine Entscheidungen, ohne Threads): wann rechnen, wie schnell, welche Dateien.
public enum OverviewPolicy {
    /// Einstellung „Vorschauen im Hintergrund“
    public enum Mode: Sendable { case always, idleOnly, off }

    /// Zustand der Decks
    public struct Decks: Equatable, Sendable {
        public var playing: Bool
        public var loading: Bool
        /// Sekunden seit dem Ende des letzten Ladens (.infinity = keins)
        public var sinceLoad: Double
        public init(playing: Bool = false, loading: Bool = false, sinceLoad: Double = .infinity) {
            self.playing = playing; self.loading = loading; self.sinceLoad = sinceLoad
        }
    }

    public enum Wait: Equatable, Sendable { case loading, playing, off }
    public enum Gate: Equatable, Sendable {
        /// volle Geschwindigkeit (kein Deck spielt)
        case full
        /// ein Arbeiter, QoS background, Pausen zwischen Blöcken und Dateien
        case throttled
        case wait(Wait)
    }

    /// nach einem Laden so lange warten (Wellenform, Analyse, erste Sekunden im Deck)
    public static let settle: Double = 4
    /// gedrosselt: Pause zwischen zwei Dateien
    public static let gap: Double = 1
    /// gedrosselt: Anteil Rechenzeit (Rest schlafen), abgerechnet je `slice` Sekunden Rechenzeit
    public static let duty: Double = 0.5
    public static let slice: Double = 0.2

    /// `explicit` = Rechtsklick → Vorschauen berechnen
    public static func gate(_ mode: Mode, explicit: Bool, decks: Decks) -> Gate {
        // Laden ist zeitkritisch (Dekodieren des ganzen Tracks): immer warten
        if decks.loading || decks.sinceLoad < settle { return .wait(.loading) }
        if !explicit, mode == .off { return .wait(.off) }
        guard decks.playing else { return .full }
        return mode == .idleOnly ? .wait(.playing) : .throttled
    }

    /// Arbeiter: Stapel ohne laufendes Deck 2, sonst 1
    public static func workers(gate: Gate, explicitQueued: Bool) -> Int {
        gate == .full && explicitQueued ? 2 : 1
    }

    /// Schlafzeit nach einem Lese-Block, der `work` Sekunden gerechnet hat
    public static func pause(after work: Double, gate: Gate) -> Double {
        gate == .throttled ? max(0, work) * (1 - duty) / duty : 0
    }

    public enum FileState: Equatable, Sendable { case local, onlineOnly, missing }

    /// Datei da, nur als Platzhalter in der Cloud (Inhalt nicht auf der Platte, SF_DATALESS) oder fehlt
    public static func fileState(path: String) -> FileState {
        var st = stat()
        guard stat(path, &st) == 0 else { return .missing }
        return (st.st_flags & 0x4000_0000) != 0 ? .onlineOnly : .local
    }

    public enum Admit: Equatable, Sendable { case read, skipOnline, skipMissing }

    /// Hintergrund liest keine reinen Cloud-Dateien (Lesen lädt die ganze Datei herunter); Rechtsklick schon
    public static func admit(explicit: Bool, file: FileState) -> Admit {
        switch file {
        case .missing: .skipMissing
        case .onlineOnly: explicit ? .read : .skipOnline
        case .local: .read
        }
    }
}
