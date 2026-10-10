import Foundation
import Observation
import MixCore
import MixEngine

/// Meldungen für die Statusleiste unten. `post` geht von jedem Thread (landet auf dem Hauptthread),
/// gleicher Schlüssel ersetzt eine aktive Meldung an ihrer Stelle (Fortschritt).
/// Ablauf: info 4 s, ok 3 s, warnung 8 s, fehler bleibt bis Klick oder Ersatz.
@MainActor @Observable
final class StatusCenter {
    static let shared = StatusCenter()

    private(set) var log = StatusLog()
    @ObservationIgnored private var cancels: [Int: @MainActor () -> Void] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var attached: MixController?

    /// letzter Ladefehler je Deck (Totenkopf in der Wellenform, DeckIdleView)
    private(set) var loadFailed: [Int: Date] = [:]

    var current: StatusMessage? { log.current }
    var history: [StatusMessage] { log.history }
    var activeCount: Int { log.active.count }

    /// von jedem Thread; auf dem Hauptthread sofort, sonst der Reihe nach über die Haupt-Queue
    nonisolated static func post(_ level: StatusMessage.Level, _ text: String, detail: String? = nil, key: String? = nil,
                                 progress: Double? = nil, progressText: String? = nil,
                                 cancel: (@MainActor @Sendable () -> Void)? = nil) {
        let now = Date()
        let run: @MainActor @Sendable () -> Void = {
            shared.post(level, text, detail: detail, key: key, progress: progress, progressText: progressText, cancel: cancel, now: now)
        }
        if Thread.isMainThread { MainActor.assumeIsolated { run() } } else { DispatchQueue.main.async { run() } }
    }

    nonisolated static func dismiss(key: String) {
        let run: @MainActor @Sendable () -> Void = { shared.log.dismiss(key: key) }
        if Thread.isMainThread { MainActor.assumeIsolated { run() } } else { DispatchQueue.main.async { run() } }
    }

    func post(_ level: StatusMessage.Level, _ text: String, detail: String? = nil, key: String? = nil,
              progress: Double? = nil, progressText: String? = nil, cancel: (@MainActor () -> Void)? = nil, now: Date = Date()) {
        let id = log.post(level, text, detail: detail, key: key, progress: progress, progressText: progressText,
                          cancellable: cancel != nil, now: now)
        cancels[id] = cancel
        if Session.isSelfTest || MixController.debug { print("[status] \(level) \(text)" + (detail.map { " · \($0)" } ?? "")); fflush(stdout) }
        schedule()
    }

    func dismiss(_ m: StatusMessage) {
        log.dismiss(id: m.id)
        cancels[m.id] = nil
    }

    func cancel(_ m: StatusMessage) {
        cancels.removeValue(forKey: m.id)?()
        log.dismiss(id: m.id)
    }

    func clearHistory() { log.clearHistory() }

    /// Kern-Meldungen (Laden, Phrasen-Anker, Plugins) übernehmen – einmal je Kern
    func attach(_ core: MixController) {
        guard attached !== core else { return }
        attached = core
        core.onNotice = { n in
            let level: StatusMessage.Level = switch n.level {
                case .info: .info
                case .ok: .ok
                case .warning: .warning
                case .error: .error
            }
            StatusCenter.post(level, n.text, detail: n.detail, key: n.key)
            if n.key.hasPrefix("load."), let d = Int(n.key.dropFirst(5)) {
                let now = Date()
                DispatchQueue.main.async { StatusCenter.shared.loadFailed[d] = n.level == .error ? now : nil }
            }
        }
    }

    /// Ablauf: Takt nur, solange etwas abläuft
    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard let next = log.nextExpiry else { return }
        let t = Timer(fire: max(next, Date().addingTimeInterval(0.05)), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var l = self.log
                if l.expire(now: Date()) {
                    for id in self.cancels.keys where !l.active.contains(where: { $0.id == id }) { self.cancels[id] = nil }
                    self.log = l
                }
                self.schedule()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
