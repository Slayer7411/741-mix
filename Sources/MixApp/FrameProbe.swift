import AppKit
import QuartzCore

/// Messung je Ereignis (UI-Selbsttest): Zeit von `begin()` bis der Hauptthread wieder wartet (beforeWaiting, nach
/// SwiftUI-Update und Core-Animation-Übergabe) = Arbeit des Hauptthreads je Bild
@MainActor
enum FrameProbe {
    private static var pending: CFTimeInterval?
    private static var last = 0.0
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
            MainActor.assumeIsolated {
                if let t0 = pending { last = (CACurrentMediaTime() - t0) * 1000; pending = nil }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    }

    /// Beginn eines Ereignisses (vor dem Zustellen)
    static func begin() { pending = CACurrentMediaTime(); last = 0 }

    /// Dauer des Ereignisses in ms seit `begin()`
    static func take() -> Double { last }

    /// Median, p95, Maximum und Bilder über 16,7 ms
    static func summary(_ v: [Double]) -> String {
        let s = v.sorted()
        guard !s.isEmpty else { return "–" }
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        return String(format: "median %.1f · p95 %.1f · max %.1f ms · über 16,7 ms: %d von %d",
                      s[s.count / 2], p95, s.last!, s.filter { $0 > 16.7 }.count, s.count)
    }
}
