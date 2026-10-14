import Foundation
import LinkKit

/// Link (Netzwerk-Tempo-Sync): MINOS führt – Tempo und Beat-Lage der Master-Clock gehen an alle Teilnehmer.
/// Läuft auf der Steuer-Queue (App-Seite von Link), nie im Audio-Thread.
public final class LinkSession: @unchecked Sendable {
    private let link: abl_link
    private let state: abl_link_session_state
    /// Quantum = ein Takt (4 Beats), damit der Takt der Teilnehmer mit dem von MINOS zusammenfällt
    public var quantum = 4.0
    /// Versatz zu den anderen Teilnehmern (positiv = die anderen spielen später)
    public var offsetMicros: Int64 = 0
    /// Nachführung (Schwellen: LinkLeadPolicy) und Diagnose
    private var policy = LinkLeadPolicy()
    public private(set) var stats = LinkStats()

    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    public static func hostTicks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
    }
    public static func seconds(hostTicks: UInt64) -> Double {
        Double(hostTicks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
    static func micros(hostTicks: UInt64) -> Int64 {
        Int64(Double(hostTicks) * Double(timebase.numer) / Double(timebase.denom) / 1000)
    }

    public init(bpm: Double = 120) {
        link = abl_link_create(bpm)
        state = abl_link_create_session_state()
    }

    deinit {
        abl_link_enable(link, false)
        abl_link_destroy_session_state(state)
        abl_link_destroy(link)
    }

    public var enabled: Bool {
        get { abl_link_is_enabled(link) }
        set {
            guard newValue != enabled else { return }
            abl_link_enable(link, newValue)
            policy.reset(); stats = LinkStats()
        }
    }

    public var peers: Int { Int(abl_link_num_peers(link)) }

    /// Abstand des eigenen Beats (hörbar zur Host-Zeit) zur Link-Zeitachse in Beats (−quantum/2 … quantum/2)
    public func phaseError(beat: Double, hostTime: UInt64) -> Double? {
        guard enabled else { return nil }
        abl_link_capture_app_session_state(link, state)
        let t = Self.micros(hostTicks: hostTime) + offsetMicros
        var diff = (beat - abl_link_beat_at_time(state, t, quantum)).truncatingRemainder(dividingBy: quantum)
        if diff > quantum / 2 { diff -= quantum } else if diff < -quantum / 2 { diff += quantum }
        return diff
    }

    /// Fenster (Max/σ) der Diagnose abholen und neu beginnen; Zähler laufen weiter
    public func takeStats() -> LinkStats {
        var r = stats; r.peers = peers
        stats.resetWindow()
        return r
    }

    /// Tempo und Beat an Link geben. `beat` ist zur Host-Zeit `hostTime` hörbar (mach_absolute_time,
    /// gleiche Uhr wie Link). Kleine Abweichungen bleiben liegen, mittlere zieht MINOS an der eigenen Clock nach
    /// (`.trim`, nur wenn `canTrim`), nur Sprünge setzen die Link-Zeitachse neu – siehe LinkLeadPolicy.
    @discardableResult
    public func lead(bpm: Double, beat: Double, hostTime: UInt64, canTrim: Bool) -> LinkLeadPolicy.Action {
        guard enabled, bpm > 0 else { return .none }
        abl_link_capture_app_session_state(link, state)
        let t = Self.micros(hostTicks: hostTime) + offsetMicros
        var changed = false
        if abs(abl_link_tempo(state) - bpm) > 0.0005 {
            abl_link_set_tempo(state, bpm, t)   // Phase bleibt zur Zeit t stetig
            changed = true
            stats.tempoSets += 1
        }
        var diff = (beat - abl_link_beat_at_time(state, t, quantum)).truncatingRemainder(dividingBy: quantum)
        if diff > quantum / 2 { diff -= quantum } else if diff < -quantum / 2 { diff += quantum }
        stats.record(diff)
        let action = policy.step(diff: diff, canTrim: canTrim)
        stats.drift = policy.drift
        switch action {
        case .force:
            abl_link_force_beat_at_time(state, beat, UInt64(max(0, t)), quantum)
            changed = true
            stats.forces += 1
        case .trim: stats.trims += 1
        case .none: break
        }
        if changed { abl_link_commit_app_session_state(link, state) }
        return action
    }
}
