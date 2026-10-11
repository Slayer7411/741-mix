import Foundation
import MixDSP
import MixMedia

/// Vorhören im Kern (Browser): eigener Player im Render-Callback auf einem eigenen Kanalpaar des Geräts, nie über den
/// Systemausgang. Laden wie die Decks über den Datei-Dienst (eigener Prozess, abbrechbar), im Hintergrund; ein neuer
/// Track oder `stop` bricht den laufenden Ladevorgang ab. Übergabe an den Kern per Generation (MixDSPPreview.h).
public final class PreviewPlayer: @unchecked Sendable {
    public enum Failure: Error, Sendable { case missing, failed(String) }

    /// Startpunkt und Schnitt aus der Dauer (Sekunden, Schnitt-Ende 0 = Track-Ende)
    public struct Plan: Sendable {
        public var start: Double, trimStart: Double, trimEnd: Double
        public init(start: Double, trimStart: Double, trimEnd: Double) { self.start = start; self.trimStart = trimStart; self.trimEnd = trimEnd }
    }

    private let engine: MixEngine
    private var core: OpaquePointer { engine.core }
    private let lock = NSLock()
    private var seq = 0
    private var audio: TrackAudio?
    /// Datei-Dienst (nil = im Prozess dekodieren)
    public var service: FileServiceClient?
    /// Dekoder im Prozess (ohne Datei-Dienst oder wenn er nicht startet)
    public var decoder: @Sendable (URL, Double, @escaping (Int) -> Bool) throws -> TrackAudio = {
        try TrackAudio.decode(url: $0, sampleRate: $1, progress: $2)
    }

    public init(engine: MixEngine) { self.engine = engine }

    /// Laden und abspielen. `plan` bekommt die Dauer; `done` (Hintergrund-Thread) meldet Dauer und Ladezeit, nicht bei Abbruch
    public func play(path: String, hardTimeout: Double, plan: @escaping @Sendable (Double) -> Plan,
                     done: @escaping @Sendable (Result<(duration: Double, seconds: Double), Failure>) -> Void) {
        let my: Int = lock.withLock { seq += 1; return seq }
        mdsp_preview_play(core, false)
        let rate = engine.sampleRate, svc = service.flatMap { $0.unavailable ? nil : $0 }, decode = decoder
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let t0 = Date()
            let current = { self.lock.withLock { self.seq == my } }
            let a: TrackAudio
            do {
                if let svc {
                    do {
                        a = try svc.decode(path: path, sampleRate: rate, hardTimeout: hardTimeout, cancelled: { !current() })
                    } catch FileServiceClient.ServiceError.unavailable {
                        a = try decode(URL(fileURLWithPath: path), rate) { _ in current() }
                    }
                } else {
                    guard FileManager.default.fileExists(atPath: path) else { throw FileServiceClient.ServiceError.missing }
                    a = try decode(URL(fileURLWithPath: path), rate) { _ in current() }
                }
            } catch FileServiceClient.ServiceError.cancelled {
                return
            } catch TrackAudio.DecodeError.cancelled {
                return
            } catch FileServiceClient.ServiceError.missing {
                if current() { done(.failure(.missing)) }
                return
            } catch {
                if current() { done(.failure(.failed(Self.reason(error)))) }
                return
            }
            let attached: Bool = lock.withLock {
                guard seq == my else { return false }
                let p = plan(a.duration)
                mdsp_preview_set_trim(core, p.trimStart, p.trimEnd)   // vor dem Puffer: der erste Block kennt ihn schon
                let gen = mdsp_preview_set_track(core, a.left, a.right, Int64(a.frames), a.sampleRate, p.start)
                mdsp_preview_play(core, true)
                release(audio, gen)
                audio = a
                return true
            }
            if attached { done(.success((a.duration, Date().timeIntervalSince(t0)))) }
        }
    }

    /// anhalten, Ladevorgang abbrechen, Puffer freigeben
    public func stop() {
        lock.withLock {
            seq += 1
            mdsp_preview_play(core, false)
            guard audio != nil else { return }
            release(audio, mdsp_preview_set_track(core, nil, nil, 0, engine.sampleRate, 0))
            audio = nil
        }
    }

    /// alten Puffer halten, bis der Audio-Thread den neuen übernommen hat (steht die Ausgabe, liest ihn niemand)
    private func release(_ old: TrackAudio?, _ gen: UInt32) {
        guard let old else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            if mdsp_preview_track_consumed(core, gen) || !engine.running { _ = old; return }
            release(old, gen)
        }
    }

    public func seek(_ seconds: Double) { mdsp_preview_seek(core, seconds) }
    public func setTrim(start: Double, end: Double) { mdsp_preview_set_trim(core, start, end) }
    public var position: Double { mdsp_preview_position(core) }
    /// false nach dem Ende (Schnitt oder Track) und nach `stop`
    public var playing: Bool { mdsp_preview_playing(core) }
    /// Ausgangspaar (erster Kanal, nil = aus); `mute` = nur Pegel messen (Selbsttest)
    public func setOutput(firstChannel: Int?, mute: Bool = false) { mdsp_preview_set_output(core, Int32(firstChannel ?? -1), mute) }
    public func setVolume(_ v: Double) { mdsp_preview_set_volume(core, Float(max(0, min(2, v)))) }
    public var level: (rms: Float, peak: Float) {
        var r: Float = 0, p: Float = 0
        mdsp_preview_levels(core, &r, &p)
        return (r, p)
    }
    /// Paar, auf das der Kern zuletzt geschrieben hat (erster Kanal), nil = keins
    public var routedPair: Int? { let c = Int(mdsp_preview_routed(core)); return c < 0 ? nil : c }

    /// Vorhör-Paar automatisch: Extern das erste freie Paar nach den Decks (sonst irgendein freies, sonst keins),
    /// Intern der Hauptausgang
    public static func autoPair(external: Bool, deckPairs: [Int], mainPair: Int, channels: Int) -> Int? {
        guard external else { return mainPair }
        let pairs = Array(stride(from: 0, to: channels - 1, by: 2)), used = Set(deckPairs)
        let after = (deckPairs.max() ?? -2) + 2
        return pairs.first { $0 >= after && !used.contains($0) } ?? pairs.first { !used.contains($0) }
    }

    private static func reason(_ e: Error) -> String {
        if case TrackAudio.DecodeError.format = e { return String(localized: "Format nicht lesbar") }
        if let s = e as? FileServiceClient.ServiceError {
            switch s {
            case let .failed(_, detail): return detail
            case .stalled: return String(localized: "keine Audiodaten (Drive antwortet nicht)")
            case .crashed: return String(localized: "Datei-Dienst abgestürzt")
            case .unresponsive: return String(localized: "Datei-Dienst antwortet nicht")
            default: break
            }
        }
        return (e as NSError).localizedDescription
    }
}
