import Foundation

/// Einplan-Verzug während eines Tests (parallele Tests, Builds): ein Faden schläft je 20 ms und misst, wie viel später
/// er aufwacht. Zeitgrenzen nach oben bekommen den größten Verzug dazu, die Produktgrenze nach unten bleibt fest
final class LagProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var worst = 0.0
    private var stop = false

    init() {
        let t = Thread { [self] in
            while !lock.withLock({ stop }) {
                let t0 = DispatchTime.now().uptimeNanoseconds
                Thread.sleep(forTimeInterval: 0.02)
                let late = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9 - 0.02
                lock.withLock { worst = Swift.max(worst, late) }
            }
        }
        t.qualityOfService = .userInitiated
        t.start()
    }

    deinit { lock.withLock { stop = true } }

    /// größter Verzug bisher (Sekunden)
    var max: Double { lock.withLock { worst } }
}
