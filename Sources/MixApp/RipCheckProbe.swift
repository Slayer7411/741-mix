import AVFoundation
import Foundation
import MixCore
import MixEngine

extension SelfTest {
    /// Rip-Prüfung: erzeugte Datei (4 Takte 128 BPM C, harter Schnitt, 60 s 126 BPM Fis) über den Datei-Weg der
    /// Warteschlange -> Befund am Bruch; Ablage, offen / Spalte / Schnitt IN / erledigt mit einem Test-Schlüssel (nur im
    /// Speicher); Laufzeit an einem Track der Collection (nur lesen). Datei danach gelöscht
    static func ripProbe(_ mix: MixModel, tracks c: [Track]) async {
        func fail(_ s: String) -> Never { log("Rip-Prüfung: \(s)"); log("RIP-PRÜFUNG FALSCH"); exit(1) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-rip-\(UUID().uuidString.prefix(8)).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard RipFixture.write(url, parts: [(128, 7.5, RipFixture.cMajor), (126, 60, RipFixture.fsMajor)]) else { fail("Datei nicht geschrieben") }
        let fixture = await Task.detached { () -> (RipCheck.Result?, Double) in
            let t0 = CACurrentMediaTime()
            let r = try? TrackAnalyzer.analyzeAndCheck(url: url, analyze: false, rip: true).rip
            return (r, CACurrentMediaTime() - t0)
        }.value
        guard let r = fixture.0, let s = r.start else { fail("kein Befund am Anfang: \(String(describing: fixture.0?.findings))") }
        guard s.kind == .foreign, abs(s.time - 7.5) < 0.05, r.end == nil else { fail("Befund \(s.id) bei \(s.time), Ende \(String(describing: r.end))") }
        // Ablage und offene Befunde (Test-Schlüssel, edits nur im Speicher)
        let rips = RipChecks.shared, key = "selftest:rip"
        let mix0 = rips.mix
        rips.mix = mix
        defer { rips.store.remove([key]); mix.edits.set(nil, for: key); rips.mix = mix0 }
        rips.store.put(r, for: key)
        let col = RipCheck.columnText(rips.open(key))
        rips.applyCut(key, s)
        let done = rips.open(key).filter { $0.cuts }.isEmpty && mix.edits.edit(for: key)?.trimStart == s.time
        guard col.hasPrefix("▸ 7,5 s"), done else { fail("Spalte „\(col)“, nach Schnitt IN offen: \(rips.open(key).map(\.id))") }
        // Laufzeit an einem echten Track: Dekodieren + Prüfung (Grid der Collection)
        var real = ""
        if let t = c.first, let a = t.gridAnchorMs {
            let res = await Task.detached { () -> (RipCheck.Result?, Double) in
                let t0 = CACurrentMediaTime()
                let r = try? TrackAnalyzer.analyzeAndCheck(url: URL(fileURLWithPath: t.path), analyze: false, rip: true, grid: (t.bpm, a / 1000)).rip
                return (r, CACurrentMediaTime() - t0)
            }.value
            real = String(format: " · Collection-Track %.0f s in %.2f s: %@", t.duration, res.1,
                          res.0.map { $0.findings.isEmpty ? "ohne Befund" : $0.findings.map { "\($0.id) \(RipCheck.shortTime($0.time))" }.joined(separator: ", ") } ?? "nicht lesbar")
        }
        log(String(format: "Rip-Prüfung: Fixture %@ bei %.2f s (Sicherheit %.2f, %@) in %.2f s · Spalte „%@“ · Schnitt IN erledigt%@",
                   s.id, s.time, s.confidence, s.cues.map(\.rawValue).joined(separator: "+"), fixture.1, col, real))
    }
}

/// Testaudio der Rip-Prüfung: Stücke aus Kick (55 Hz) je Beat, Hat auf dem Offbeat, Akkord-Fläche, hart aneinander
enum RipFixture {
    static let cMajor = [130.81, 164.81, 196.0, 261.63, 329.63, 392.0]
    static let fsMajor = [185.0, 233.08, 277.18, 369.99, 466.16, 554.37]

    static func samples(bpm: Double, seconds: Double, chord: [Double], rate: Double) -> [Float] {
        let n = Int(seconds * rate)
        var x = [Float](repeating: 0, count: n)
        let period = 60 / bpm
        var k = 0
        while Double(k) * period < seconds {
            let s0 = Int(Double(k) * period * rate), sh = Int((Double(k) + 0.5) * period * rate)
            for i in 0..<Int(0.25 * rate) where s0 + i < n {
                let t = Double(i) / rate
                x[s0 + i] += 0.6 * Float(sin(2 * .pi * 55 * t) * exp(-t / 0.09))
            }
            for i in 0..<Int(0.02 * rate) where sh + i < n {
                let t = Double(i) / rate
                x[sh + i] += 0.15 * Float(sin(2 * .pi * 6000 * t) * exp(-t / 0.006))
            }
            k += 1
        }
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.0
            for f in chord { v += sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * 2 * f * t) }
            x[i] += Float(0.04 * v)
        }
        return x
    }

    /// WAV (Float, Stereo, 44,1 kHz) aus Stücken (BPM, Sekunden, Akkord)
    static func write(_ url: URL, parts: [(Double, Double, [Double])], rate: Double = 44100) -> Bool {
        let x = parts.flatMap { samples(bpm: $0.0, seconds: $0.1, chord: $0.2, rate: rate) }
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)),
              let file = try? AVAudioFile(forWriting: url, settings: fmt.settings) else { return false }
        buf.frameLength = AVAudioFrameCount(x.count)
        for ch in 0..<2 { x.withUnsafeBufferPointer { buf.floatChannelData![ch].update(from: $0.baseAddress!, count: x.count) } }
        return (try? file.write(from: buf)) != nil
    }
}
