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
    /// geglättete Phasenabweichung zu Link; erst ab Schwelle wird die Link-Zeitachse neu gesetzt
    private var drift = 0.0

    private static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
    public static func hostTicks(seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1e9 * Double(timebase.denom) / Double(timebase.numer))
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
        set { if newValue != enabled { abl_link_enable(link, newValue) } }
    }

    public var peers: Int { Int(abl_link_num_peers(link)) }

    /// Tempo und Beat an Link geben. `beat` ist zur Host-Zeit `hostTime` hörbar (mach_absolute_time,
    /// gleiche Uhr wie Link). Kleine Abweichungen (Callback-Jitter) werden geglättet statt jedes Mal neu gesetzt.
    public func lead(bpm: Double, beat: Double, hostTime: UInt64) {
        guard enabled, bpm > 0 else { return }
        abl_link_capture_app_session_state(link, state)
        let t = Self.micros(hostTicks: hostTime) + offsetMicros
        var changed = false
        if abs(abl_link_tempo(state) - bpm) > 0.0005 {
            abl_link_set_tempo(state, bpm, t)
            changed = true
        }
        var diff = (beat - abl_link_beat_at_time(state, t, quantum)).truncatingRemainder(dividingBy: quantum)
        if diff > quantum / 2 { diff -= quantum } else if diff < -quantum / 2 { diff += quantum }
        drift += (diff - drift) * 0.1
        if abs(diff) > 0.1 || abs(drift) > 0.01 {
            abl_link_force_beat_at_time(state, beat, UInt64(max(0, t)), quantum)
            drift = 0
            changed = true
        }
        if changed { abl_link_commit_app_session_state(link, state) }
    }
}
