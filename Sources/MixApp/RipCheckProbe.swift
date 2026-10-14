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
        let marked = await ripRangeProbe(mix, url: url, result: r)
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
        log(String(format: "Rip-Prüfung: Fixture %@ bei %.2f s (Sicherheit %.2f, %@) in %.2f s · Spalte „%@“ · Schnitt IN erledigt · %@%@",
                   s.id, s.time, s.confidence, s.cues.map(\.rawValue).joined(separator: "+"), fixture.1, col, marked, real))
    }

    /// Befund im Speicher, Fixture in das letzte Deck (EDIT an): Laden markiert den Bereich 0 … Befund mit „RIP · …“,
    /// REMOVE (Schnittliste) erledigt den Befund, der Bereich ist weg. Edits nur im Speicher
    static func ripRangeProbe(_ mix: MixModel, url: URL, result r: RipCheck.Result) async -> String {
        func fail(_ s: String) -> Never { log("Rip-Bereich: \(s)"); log("RIP-PRÜFUNG FALSCH"); exit(1) }
        guard let s = r.start else { fail("kein Befund") }
        let d = mix.decks.count - 1, rips = RipChecks.shared
        var t = Track(key: url.path, path: url.path)
        t.title = "Rip Fixture"
        t.bpm = 126
        t.duration = r.duration
        t.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: s.time * 1000, lengthMs: 0, hotcue: -1)]
        rips.store.put(r, for: t.key)
        let wasEditing = mix.editing(d), onLoad = mix.prefs.ui.ripMarkOnLoad
        defer { rips.store.remove([t.key]); mix.prefs.ui.ripMarkOnLoad = onLoad; mix.setRange(d, nil); mix.setEditing(d, wasEditing); mix.pull() }
        mix.prefs.ui.ripMarkOnLoad = true
        mix.setEditing(d, true)
        guard mix.load(t, deck: d, force: true) else { fail("Fixture lädt nicht in Deck \(deckLetters[d])") }
        for _ in 0..<1500 where mix.ripMark(d) == nil { mix.pull(); try? await Task.sleep(for: .milliseconds(20)) }
        guard let m = mix.ripMark(d), let range = mix.range(d) else { fail("Laden markiert keinen Bereich (\(mix.deck(d).error ?? "-"))") }
        let label = mix.rangeMarked(d, grid: mix.deck(d).grid)?.label ?? ""
        guard m.finding.id == s.id, range.start == 0, abs(range.end - s.time) < 1e-3, label.hasPrefix("RIP · ") else {
            fail("Bereich \(range) „\(label)“ für \(m.finding.id)")
        }
        let dur0 = mix.deck(d).duration
        mix.editAction(d, .remove)
        for _ in 0..<500 where mix.editSession(d)?.rendering == true { try? await Task.sleep(for: .milliseconds(20)) }
        mix.pull()
        let open = rips.open(t.key).filter(\.cuts).map(\.id), done = rips.store.entry(for: t.key)?.done ?? []
        let dur1 = mix.deck(d).duration
        guard open.isEmpty, done == [s.id], mix.range(d) == nil, mix.ripMark(d) == nil, abs(dur0 - dur1 - range.length) < 0.01 else {
            fail("nach REMOVE: offen \(open), erledigt \(done), Bereich \(String(describing: mix.range(d))), Dauer \(dur0) -> \(dur1)")
        }
        return "Laden markiert „\(label)“ · REMOVE -> erledigt"
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
