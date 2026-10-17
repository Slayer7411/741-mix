import Foundation

/// Wie MINOS als Link-Führer auf eine Phasenabweichung reagiert – ohne LinkKit, damit testbar.
/// Eingang je Steuertick (200 Hz): `diff` = eigener Beat − Beat der Link-Zeitachse zur selben Host-Zeit.
/// Jedes Neusetzen der Link-Zeitachse (force) lässt die Teilnehmer springen; deshalb nur bei echten Sprüngen.
public struct LinkLeadPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// MINOS-Clock um −Wert Beats verschieben (Link bleibt unberührt)
        case trim(Double)
        /// Link-Zeitachse auf den eigenen Beat setzen
        case force
    }

    /// Glättung je Tick: Zeitkonstante ≈ 10 Ticks = 50 ms. Stempel-Jitter ±3 ms (±0,0064 Beats bei 128 BPM)
    /// bleibt danach bei etwa ±0,001 Beats.
    public static let smoothing = 0.1
    /// ab hier zieht MINOS die eigene Clock nach (≈ 2,3 ms bei 128 BPM): gut 5× über dem geglätteten Jitter;
    /// so klein, dass gesyncte Decks den Schritt kaum sehen (Phase-Lock ignoriert < 0,004 Beats)
    public static let trimTolerance = 0.005
    /// darunter wird Link nie angefasst (≈ 9 ms bei 128 BPM): 3× der rohe Jitter, unter der Schwelle, ab der zwei
    /// Transienten als Doppelschlag hörbar werden (~10 ms). Gilt, wenn die Clock am Master-Deck hängt (AUTO).
    public static let tolerance = 0.02
    /// echter Sprung (≈ 117 ms bei 128 BPM): Clock/Master gewechselt, Deck gesprungen, Gerät neu.
    /// Weder Jitter noch Uhren-Drift (Geräte- vs. Host-Uhr, ~50 ppm) erreichen das zwischen zwei Korrekturen.
    public static let jumpThreshold = 0.25
    /// so viele Ticks in Folge über `jumpThreshold`, bevor neu gesetzt wird (15 ms): ein Ausreißer-Stempel reicht nicht
    public static let jumpTicks = 3
    /// Ticks Pause nach jeder Korrektur (100 ms): der neue Beat steht erst nach dem nächsten Audio-Block im Stempel
    public static let holdoff = 20

    public private(set) var drift = 0.0
    private var aligned = false
    private var over = 0
    private var hold = 0

    public init() {}

    /// nach Ein-/Ausschalten von Link: die erste Abweichung wird einmal gesetzt
    public mutating func reset() { self = Self() }

    /// `canTrim`: die Clock läuft frei (MASTER-Modus oder kein Master-Deck spielt). Hängt sie am Master-Deck,
    /// ist die Musik die Referenz – dann wird Link ab `tolerance` neu gesetzt.
    public mutating func step(diff: Double, canTrim: Bool) -> Action {
        guard diff.isFinite else { return .none }
        if hold > 0 { hold -= 1; return .none }
        if !aligned {
            aligned = true
            return abs(diff) > Self.trimTolerance ? act(.force) : .none
        }
        if abs(diff) > Self.jumpThreshold {
            over += 1
            return over >= Self.jumpTicks ? act(.force) : .none
        }
        over = 0
        drift += (diff - drift) * Self.smoothing
        if canTrim {
            if abs(drift) > Self.trimTolerance { return act(.trim(drift)) }
        } else if abs(drift) > Self.tolerance {
            return act(.force)
        }
        return .none
    }

    private mutating func act(_ a: Action) -> Action {
        drift = 0; over = 0; hold = Self.holdoff
        return a
    }
}

/// Wie MINOS dem Link-Takt folgt (Gegenstück zu LinkLeadPolicy, Link bleibt unberührt). Eingang je Steuertick:
/// `diff` = eigener Beat − Beat der Link-Zeitachse zur selben Host-Zeit. Kleine Abweichungen zieht die Clock nach,
/// ab `jumpTolerance` (geglättet) springt sie auf die Link-Zeitachse.
public struct LinkFollowPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Clock um −Wert Beats verschieben
        case trim(Double)
        /// Clock um −Wert Beats springen lassen (Phase und Takt-Lage)
        case jump(Double)
    }

    /// ab hier (geglättet, ≈ 0,02 Beats) springt die Clock wie bei der Clock am Master-Deck
    public static let jumpTolerance = LinkLeadPolicy.tolerance
    public static let trimTolerance = LinkLeadPolicy.trimTolerance

    public private(set) var drift = 0.0
    private var aligned = false
    private var hold = 0

    public init() {}

    public mutating func reset() { self = Self() }

    public mutating func step(diff: Double) -> Action {
        guard diff.isFinite else { return .none }
        if hold > 0 { hold -= 1; return .none }
        if !aligned {
            aligned = true
            return abs(diff) > Self.trimTolerance ? act(.jump(diff)) : .none
        }
        drift += (diff - drift) * LinkLeadPolicy.smoothing
        if abs(drift) > Self.jumpTolerance { return act(.jump(diff)) }
        if abs(drift) > Self.trimTolerance { return act(.trim(drift)) }
        return .none
    }

    private mutating func act(_ a: Action) -> Action {
        drift = 0; hold = LinkLeadPolicy.holdoff
        return a
    }
}

/// Link-Diagnose: Zähler seit dem Einschalten, letzte Werte, Fenster (Max/σ der Abweichung) seit dem letzten Abholen
public struct LinkStats: Sendable, Equatable {
    /// Link-Zeitachse neu gesetzt (force), Tempo an Link gegeben, MINOS-Clock nachgezogen
    public var forces = 0, tempoSets = 0, trims = 0
    /// letzte Abweichung und geglättete Drift, Beats
    public var lastDiff: Double?
    public var drift = 0.0
    public var peers = 0
    public var windowMax = 0.0, windowCount = 0
    var windowSum = 0.0, windowSumSq = 0.0
    public init() {}

    public var windowSigma: Double {
        guard windowCount > 1 else { return 0 }
        let m = windowSum / Double(windowCount)
        return (max(0, windowSumSq / Double(windowCount) - m * m)).squareRoot()
    }

    public mutating func record(_ diff: Double) {
        lastDiff = diff
        windowMax = max(windowMax, abs(diff))
        windowSum += diff; windowSumSq += diff * diff; windowCount += 1
    }

    public mutating func resetWindow() { windowMax = 0; windowSum = 0; windowSumSq = 0; windowCount = 0 }
}
