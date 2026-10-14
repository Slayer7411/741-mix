import Foundation
import MixDSP
import MixMedia

/// Ringpuffer Audio-Thread -> Schreib-Queue (Stereo, MixDSPRecord.h). Ein Schreiber (Audio-Thread oder Test), ein Leser.
/// Lebt mindestens so lange wie der Abgriff, der hineinschreibt.
public final class RecordRing: @unchecked Sendable {
    let ptr: OpaquePointer

    /// Platz für mindestens `capacityFrames` Frames (Zweierpotenz). nil = kein Speicher
    public init?(capacityFrames: Int) {
        guard let p = mdsp_ring_create(Int32(clamping: capacityFrames)) else { return nil }
        ptr = p
    }

    deinit { mdsp_ring_destroy(ptr) }

    public var capacity: Int { Int(mdsp_ring_capacity(ptr)) }
    public var available: Int { Int(mdsp_ring_available(ptr)) }
    /// an = Samples landen im Ring (Pegel gibt es immer)
    public var armed: Bool {
        get { mdsp_ring_armed(ptr) }
        set { mdsp_ring_set_armed(ptr, newValue) }
    }
    /// verworfene Blöcke / Frames und geschriebene Frames seit `reset`
    public var overflows: Int { Int(mdsp_ring_overflows(ptr)) }
    public var droppedFrames: Int { Int(mdsp_ring_dropped_frames(ptr)) }
    public var writtenFrames: Int { Int(mdsp_ring_written_frames(ptr)) }

    /// Gelesenes verwerfen, Zähler auf 0 (Leser, vor dem Scharfschalten)
    public func reset() { mdsp_ring_reset(ptr) }

    /// wie der Audio-Thread schreiben (Tests, Messung)
    public func write(left: UnsafePointer<Float>, right: UnsafePointer<Float>?, count: Int) {
        mdsp_ring_write(ptr, left, right, Int32(count))
    }

    /// bis zu `max` Frames lesen, liefert die Anzahl
    public func read(left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?, max: Int) -> Int {
        Int(mdsp_ring_read(ptr, left, right, Int32(clamping: max)))
    }

    /// Spitze L/R seit dem letzten Abholen (ein Abholer)
    public func takePeak() -> (left: Float, right: Float) {
        var l: Float = 0, r: Float = 0
        mdsp_ring_take_peak(ptr, &l, &r)
        return (l, r)
    }

    /// Ring für eine Aufnahme: 2^21 Frames (44,1 kHz 47 s, 192 kHz 10 s), 16 MB
    public static let standardFrames = 1 << 21
}

/// Liest einen Ring auf einer eigenen Queue alle 250 ms aus und schreibt Blöcke von etwa einer Sekunde in die Datei.
/// Start: Ring leeren und scharf schalten. Stopp: entschärfen, den letzten Block abwarten, Rest schreiben, Datei schließen.
public final class RecordSink: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var frames = 0
        public var overflows = 0
        public var droppedFrames = 0
        public var error: String?
        public init() {}
    }

    public let url: URL
    public let sampleRate: Double
    private let ring: RecordRing
    private let file: RecordingFile
    private let queue = DispatchQueue(label: "minos741.record", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let block: Int
    private let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    private var staged = 0
    private var finished = false
    private let lock = NSLock()
    private var _stats = Stats()
    public var stats: Stats { lock.withLock { _stats } }
    /// Schreibfehler (Queue der Aufnahme); die Aufnahme steht danach, die Datei ist geschlossen
    public var onError: (@Sendable (String) -> Void)?

    public init(ring: RecordRing, url: URL, kind: RecordingFile.Kind, sampleRate: Double) throws {
        self.ring = ring
        self.url = url
        self.sampleRate = sampleRate
        block = max(4096, Int(sampleRate.rounded()))
        left = .allocate(capacity: block)
        right = .allocate(capacity: block)
        file = try RecordingFile(url: url, kind: kind, sampleRate: sampleRate)
    }

    deinit { left.deallocate(); right.deallocate() }

    public func start() {
        queue.sync {
            ring.reset()
            ring.armed = true
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.25, repeating: 0.25, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.drain(final: false) }
            timer = t
            t.resume()
        }
    }

    /// entschärfen, letzten Block des Audio-Threads abwarten (`settle`), Rest schreiben, schließen; `done` auf der Queue
    public func stop(settle: Double = 0.08, _ done: @escaping @Sendable (Stats) -> Void) {
        queue.async { [self] in
            ring.armed = false
            timer?.cancel(); timer = nil
            queue.asyncAfter(deadline: .now() + settle) { [self] in done(finish()) }
        }
    }

    /// wie `stop`, blockiert bis die Datei zu ist (Beenden der App)
    @discardableResult
    public func stopNow() -> Stats {
        queue.sync {
            ring.armed = false
            timer?.cancel(); timer = nil
            usleep(50_000)
            return finish()
        }
    }

    private func finish() -> Stats {
        if !finished {
            drain(final: true)
            file.close()
            finished = true
        }
        return stats
    }

    private func drain(final: Bool) {
        guard !finished else { return }
        while true {
            let n = ring.read(left: left + staged, right: right + staged, max: block - staged)
            staged += n
            if staged == block || (final && staged > 0 && n == 0) { flush() }
            if n == 0 || finished { break }
        }
        let o = ring.overflows, d = ring.droppedFrames
        lock.withLock { _stats.overflows = o; _stats.droppedFrames = d }
    }

    private func flush() {
        do {
            try file.append(left: left, right: right, count: staged)
            let f = file.frames
            lock.withLock { _stats.frames = f }
            staged = 0
        } catch {
            let why = error.localizedDescription
            lock.withLock { _stats.error = why }
            ring.armed = false
            timer?.cancel(); timer = nil
            file.close()
            finished = true
            onError?(why)
        }
    }
}

extension MixEngine {
    /// Abgriff des internen Masters (nach Begrenzung, ohne Metronom und Vorhören) auf `ring`, nil = aus.
    /// Der Ring muss leben, bis `masterTapReleased` true ist (oder die Ausgabe steht)
    public func setMasterTap(_ ring: RecordRing?, firstChannel: Int) {
        mdsp_set_record_tap(core, ring?.ptr, Int32(firstChannel))
    }

    public func masterTapReleased(_ ring: RecordRing) -> Bool { mdsp_record_tap_released(core, ring.ptr) }

    /// Rechenzeit des Master-Abgriffs im Audio-Thread seit dem letzten Abholen: gesamt, schwerster Block (ms), Blöcke
    public func takeTapCost() -> (totalMs: Double, worstMs: Double, blocks: Int) {
        var t: UInt64 = 0, w: UInt64 = 0, b: UInt32 = 0
        mdsp_record_tap_cost(core, &t, &w, &b)
        return (Double(t) / 1e6, Double(w) / 1e6, Int(b))
    }
}
