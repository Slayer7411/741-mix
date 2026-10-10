import Foundation
import LinkKit

/// Ableton Link: MINOS führt – Tempo und Beat-Lage der Master-Clock gehen an alle Teilnehmer (z. B. Ableton).
/// Läuft auf der Steuer-Queue (App-Seite von Link), nie im Audio-Thread.
public final class LinkSession: @unchecked Sendable {
    private let link: abl_link
    private let state: abl_link_session_state
    /// Quantum = ein Takt (4 Beats), damit Abletons Takt mit dem von MINOS zusammenfällt
    public var quantum = 4.0
    /// Zeit bis der berechnete Beat hörbar ist (Ausgabelatenz)
    public var latencyMicros: Int64 = 10_000

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

    /// Tempo und Beat an Link geben, nur wenn etwas abweicht (andere Teilnehmer werden überstimmt)
    public func lead(bpm: Double, beat: Double) {
        guard enabled, bpm > 0 else { return }
        abl_link_capture_app_session_state(link, state)
        let now = abl_link_clock_micros(link) + latencyMicros
        var changed = false
        if abs(abl_link_tempo(state) - bpm) > 0.0005 {
            abl_link_set_tempo(state, bpm, now)
            changed = true
        }
        var diff = (beat - abl_link_beat_at_time(state, now, quantum)).truncatingRemainder(dividingBy: quantum)
        if diff > quantum / 2 { diff -= quantum } else if diff < -quantum / 2 { diff += quantum }
        if changed || abs(diff) > 0.005 {
            abl_link_force_beat_at_time(state, beat, UInt64(max(0, now)), quantum)
            changed = true
        }
        if changed { abl_link_commit_app_session_state(link, state) }
    }
}
