import AVFoundation
import Foundation
import Testing
import MixCore
@testable import MixEngine

/// Synthetischer Track: Kick (55 Hz, abklingend) auf jedem Beat, Hat (6 kHz, kurz) auf den Offbeats, ab Takt 9 ein
/// Pad (Akkord), ab Takt 17 eine zweite Hat-Lage – Strukturwechsel auf 8-Takt-Grenzen wie in echter Musik
private func clickTrack(bpm: Double, offset: Double, seconds: Double, rate: Double = 44100, level: Float = 0.8,
                        chord: [Double] = [130.81, 164.81, 196.0]) -> (l: [Float], r: [Float]) {
    let n = Int(seconds * rate)
    var l = [Float](repeating: 0, count: n)
    let beat = 60 / bpm
    var k = 0
    while true {
        let t0 = offset + Double(k) * beat
        let s0 = Int(t0 * rate)
        if s0 >= n { break }
        // Kick: 55 Hz, Abklingzeit 90 ms, Anschlag ohne Rampe
        for i in 0..<Int(0.25 * rate) where s0 + i < n {
            let t = Double(i) / rate
            l[s0 + i] += level * Float(sin(2 * .pi * 55 * t) * exp(-t / 0.09))
        }
        // Hat auf dem Offbeat (ab Takt 17 auf jedem Achtel)
        let hats = k >= 64 ? [0.25, 0.5, 0.75] : [0.5]
        for h in hats {
            let sh = Int((t0 + h * beat) * rate)
            for i in 0..<Int(0.02 * rate) where sh + i < n {
                let t = Double(i) / rate
                l[sh + i] += 0.25 * level * Float(sin(2 * .pi * 6000 * t) * exp(-t / 0.006))
            }
        }
        k += 1
    }
    // Pad ab Takt 9: Akkord, leise
    let padStart = Int((offset + 32 * beat) * rate)
    if padStart < n {
        for i in padStart..<n {
            let t = Double(i) / rate
            var v = 0.0
            for f in chord { v += sin(2 * .pi * f * t) + 0.5 * sin(2 * .pi * 2 * f * t) }
            l[i] += 0.08 * level * Float(v)
        }
    }
    return (l, l)
}

private func analyze(_ s: (l: [Float], r: [Float]), rate: Double = 44100) throws -> TrackAnalyzer.Result {
    try s.l.withUnsafeBufferPointer { lp in
        try s.r.withUnsafeBufferPointer { rp in
            try TrackAnalyzer.analyze(left: lp.baseAddress!, right: rp.baseAddress!, frames: lp.count, sampleRate: rate)
        }
    }
}

/// Abstand des Ankers zum Raster der echten Beats in ms (Anker darf auf jedem Beat liegen)
private func gridError(_ anchor: Double, offset: Double, bpm: Double) -> Double {
    let beat = 60 / bpm
    let d = (anchor - offset) / beat
    return abs(d - d.rounded()) * beat * 1000
}

/// Klick-Track 127,3 BPM, erster Schlag bei 0,350 s: Tempo ±0,05 BPM, Anker ±5 ms auf dem Beat, Anker ≥ 0
@Test func analyzerFindsTempoAndGrid() throws {
    let bpm = 127.3, offset = 0.35
    let r = try analyze(clickTrack(bpm: bpm, offset: offset, seconds: 90))
    #expect(abs(r.bpm - bpm) < 0.05, "bpm \(r.bpm)")
    #expect(gridError(r.anchor, offset: offset, bpm: bpm) < 5, "anchor \(r.anchor)")
    #expect(r.anchor >= 0 && r.anchor < 32 * 60 / bpm + offset + 0.01)
    #expect(r.tempoConfidence > 0.2)
    #expect(abs(r.duration - 90) < 0.01)
}

/// anderes Tempo, anderer Versatz, 48 kHz (Dezimierung ×4 auf 12 kHz): gleiche Genauigkeit; Doppel-/Halbtempo nicht gewählt
@Test func analyzerTempoAt48k() throws {
    let bpm = 140.0, offset = 1.234
    let r = try analyze(clickTrack(bpm: bpm, offset: offset, seconds: 90, rate: 48000), rate: 48000)
    #expect(abs(r.bpm - bpm) < 0.05, "bpm \(r.bpm)")
    #expect(gridError(r.anchor, offset: offset, bpm: bpm) < 5, "anchor \(r.anchor)")
}

/// langsamer Track (96 BPM) bleibt 96, nicht 192
@Test func analyzerSlowTempo() throws {
    let bpm = 96.0, offset = 0.5
    let r = try analyze(clickTrack(bpm: bpm, offset: offset, seconds: 90))
    #expect(abs(r.bpm - bpm) < 0.05, "bpm \(r.bpm)")
    #expect(gridError(r.anchor, offset: offset, bpm: bpm) < 5, "anchor \(r.anchor)")
}

/// Akkorde: C-Dur -> 0 (1d), a-Moll -> 21 (1m), fis-Moll -> 18 (11m)
@Test func analyzerFindsKey() throws {
    func chord(_ freqs: [Double], seconds: Double = 20, rate: Double = 44100) -> (l: [Float], r: [Float]) {
        let n = Int(seconds * rate)
        var l = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.0
            for (j, f) in freqs.enumerated() { v += (1 / Double(j + 1)) * sin(2 * .pi * f * t) + 0.3 * sin(2 * .pi * 2 * f * t) }
            l[i] = 0.2 * Float(v)
        }
        return (l, l)
    }
    // C2 E2 G2 C3 E3 G3 C4 – Dreiklang über drei Oktaven
    let cMajor = chord([65.41, 82.41, 98.0, 130.81, 164.81, 196.0, 261.63, 329.63, 392.0])
    let rc = try analyze(cMajor)
    #expect(rc.musicalKey == 0, "key \(rc.musicalKey)")
    #expect(Track.openKey(code: rc.musicalKey) == "1d")
    // A2 C3 E3 A3 C4 E4
    let aMinor = chord([110.0, 130.81, 164.81, 220.0, 261.63, 329.63, 440.0])
    let ra = try analyze(aMinor)
    #expect(ra.musicalKey == 21, "key \(ra.musicalKey)")
    #expect(Track.openKey(code: ra.musicalKey) == "1m")
    // F#2 A2 C#3 F#3 A3 C#4
    let fsMinor = chord([92.5, 110.0, 138.59, 185.0, 220.0, 277.18, 369.99])
    let rf = try analyze(fsMinor)
    #expect(rf.musicalKey == 18, "key \(rf.musicalKey)")
    #expect(rf.keyClarity > 0)
}

/// Pegel: Sinus −20 dBFS Spitze -> Spitze −20 dB; PERCEIVED_DB ist die Verstärkung auf die Referenz (6 dB leiser = 6 dB mehr)
@Test func analyzerLoudness() throws {
    func sine(_ amp: Float, seconds: Double = 12, rate: Double = 44100) -> (l: [Float], r: [Float]) {
        let n = Int(seconds * rate)
        let l = (0..<n).map { amp * Float(sin(2 * .pi * 440 * Double($0) / rate)) }
        return (l, l)
    }
    let a = try analyze(sine(0.1)), b = try analyze(sine(0.05))
    #expect(abs(a.peakDb + 20) < 0.1)
    #expect(abs(b.peakDb + 26.02) < 0.1)
    #expect(abs((b.perceivedDb - a.perceivedDb) - 6.02) < 0.1)
    // RMS eines Sinus mit Spitze 0,1 = −23 dBFS; Verstärkung = Referenz − Pegel
    #expect(abs(a.perceivedDb - (TrackAnalyzer.loudnessReference + 23.01)) < 0.1)
    #expect(abs(a.analysis.perceivedDb! - a.perceivedDb) < 1e-9)
}

/// Stille und kurze Dateien: kein Tempo, keine Tonart, kein Absturz
@Test func analyzerSilenceAndShort() throws {
    let silent = (l: [Float](repeating: 0, count: 44100 * 20), r: [Float](repeating: 0, count: 44100 * 20))
    let r = try analyze(silent)
    #expect(r.bpm == 0 && r.musicalKey == -1 && r.analysis.bpm == nil && r.analysis.musicalKey == nil)
    let short = try analyze(clickTrack(bpm: 128, offset: 0.1, seconds: 2))
    #expect(short.bpm == 0 && abs(short.duration - 2) < 0.01)
}

/// Datei-Weg (blockweise lesen, dezimieren): gleiches Ergebnis wie aus dem Speicher, deterministisch, Abbruch über checkpoint
@Test func analyzerFromFileMatchesMemory() throws {
    let s = clickTrack(bpm: 124.0, offset: 0.8, seconds: 80)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("minos-ana-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    // Schreiben in eigenem Block: die Datei ist erst geschlossen vollständig
    try {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.l.count))!
        buf.frameLength = AVAudioFrameCount(s.l.count)
        for i in 0..<s.l.count { buf.floatChannelData![0][i] = s.l[i]; buf.floatChannelData![1][i] = s.r[i] }
        try file.write(from: buf)
    }()
    let a = try TrackAnalyzer.analyze(url: url), b = try analyze(s), c = try TrackAnalyzer.analyze(url: url)
    #expect(a == c)
    #expect(abs(a.bpm - 124) < 0.05 && abs(a.bpm - b.bpm) < 0.01)
    #expect(abs(a.anchor - b.anchor) < 0.002)
    #expect(a.musicalKey == b.musicalKey && abs(a.perceivedDb - b.perceivedDb) < 0.05)
    struct Stop: Error {}
    var calls = 0
    #expect(throws: Stop.self) { _ = try TrackAnalyzer.analyze(url: url) { calls += 1; if calls == 2 { throw Stop() } } }
    #expect(calls == 2)
}

/// Überlagerung: nur gesetzte Felder, Grid-Cue ersetzt oder neu, Tonart-Text wie die Collection, ✓ analysiert
@Test func analysisAppliesToTrack() {
    var t = Track(key: "k", path: "/x.mp3")
    t.bpm = 128; t.cues = [Cue(name: "AutoGrid", kind: .grid, startMs: 100, lengthMs: 0, hotcue: 0)]
    let a = TrackAnalysis(bpm: 127.5, gridAnchorMs: 350.25, musicalKey: 21, perceivedDb: 1.5, peakDb: -0.1)
    let u = a.apply(to: t)
    #expect(u.bpm == 127.5 && u.gridAnchorMs == 350.25 && u.cues.count == 1 && u.musicalKey == 21 && u.keyText == "1m")
    #expect(u.perceivedDb == 1.5 && u.peakDb == -0.1 && u.ownAnalysis && u.analyzed)
    let only = a.restricted(to: .key)
    let v = only.apply(to: t)
    #expect(v.bpm == 128 && v.gridAnchorMs == 100 && v.musicalKey == 21 && v.perceivedDb == nil)
    #expect(TrackAnalysis.missing(in: t) == [.key, .loudness])
    #expect(TrackAnalysis.missing(in: Track(key: "l", path: "/l")) == .all)
    let merged = only.merged(with: a.restricted(to: .tempo))
    #expect(merged.fields == [.tempo, .key] && merged.bpm == 127.5 && merged.musicalKey == 21 && !merged.written)
    var g = Track(key: "g", path: "/g")
    g = TrackAnalysis(bpm: 120, gridAnchorMs: 10).apply(to: g)
    #expect(g.cues.first?.kind == .grid && g.cues.first?.hotcue == -1 && g.gridAnchorMs == 10)
}

// MARK: - Vergleich mit der Collection (nur auf Wunsch)

/// MIX741_ANALYZE_NML=<collection.nml> [MIX741_ANALYZE_N=20]: lokale, schon vorhandene Dateien der Collection analysieren
/// und BPM / Tonart / Lautheit gegen die Collection-Werte stellen. Druckt eine Tabelle und Trefferquoten.
@Test func analyzerAgainstCollection() throws {
    guard let nml = ProcessInfo.processInfo.environment["MIX741_ANALYZE_NML"] else { return }
    let want = Int(ProcessInfo.processInfo.environment["MIX741_ANALYZE_N"] ?? "") ?? 20
    let all = try NMLParser.parse(url: URL(fileURLWithPath: nml)).tracks
    let eligible = all.filter {
        $0.bpm > 0 && $0.musicalKey >= 0 && $0.perceivedDb != nil && $0.gridAnchorMs != nil && $0.duration > 60
            && OverviewPolicy.fileState(path: $0.path) == .local
    }
    let step = max(1, eligible.count / want)
    let picked = stride(from: 0, to: eligible.count, by: step).prefix(want).map { eligible[$0] }
    print("[analyze] \(all.count) tracks, \(eligible.count) local with analysis, \(picked.count) picked")
    var bpmHits = 0, bpmOctave = 0, keyHits = 0, keyRelative = 0, gridHits = 0, n = 0
    var loudDiff: [Double] = [], times: [Double] = []
    func keyRelated(_ a: Int, _ b: Int) -> Bool {
        // gleich, relative Dur/Moll (C <-> Am), Quinte/Quarte im Quintenzirkel
        if a == b { return true }
        let (am, bm) = (a < 12, b < 12), (at, bt) = (a % 12, b % 12)
        if am != bm { return (am ? (at + 9) % 12 == bt : (bt + 9) % 12 == at) }
        return [5, 7].contains(((at - bt) % 12 + 12) % 12)
    }
    for t in picked {
        let t0 = Date()
        guard let r = try? TrackAnalyzer.analyze(url: URL(fileURLWithPath: t.path)) else { print("[analyze] unreadable \(t.path)"); continue }
        let dt = Date().timeIntervalSince(t0)
        times.append(dt)
        n += 1
        let ratio = r.bpm / t.bpm
        let bpmOk = abs(r.bpm - t.bpm) <= 0.1
        let octave = !bpmOk && (abs(ratio - 2) < 0.002 || abs(ratio - 0.5) < 0.0005)
        if bpmOk { bpmHits += 1 }
        if octave { bpmOctave += 1 }
        let keyOk = r.musicalKey == t.musicalKey
        if keyOk { keyHits += 1 } else if keyRelated(r.musicalKey, t.musicalKey) { keyRelative += 1 }
        // Grid: Anker der Collection auf dem eigenen Raster (mod Beat), in ms
        var gridMs = -1.0
        if r.bpm > 0, let ga = t.gridAnchorMs {
            let beat = 60 / r.bpm
            let d = (ga / 1000 - r.anchor) / beat
            gridMs = abs(d - d.rounded()) * beat * 1000
            if bpmOk || octave, gridMs < 20 { gridHits += 1 }
        }
        let ld = r.perceivedDb - (t.perceivedDb ?? 0)
        loudDiff.append(ld)
        print(String(format: "[analyze] %@ bpm %.3f/%.3f %@ · key %@/%@ %@ · grid %.0f ms · loud %+.2f/%+.2f · peak %.2f/%.2f · %.1f s · %@ – %@",
                     bpmOk ? "OK " : octave ? "OCT" : "MIS", r.bpm, t.bpm, r.tempoConfidence.formatted(.number.precision(.fractionLength(2))),
                     Track.openKey(code: max(0, r.musicalKey)), t.openKey, keyOk ? "OK" : keyRelated(r.musicalKey, t.musicalKey) ? "REL" : "MIS",
                     gridMs, r.perceivedDb, t.perceivedDb ?? 0, r.peakDb, t.peakDb ?? 0, dt, t.artist, t.title))
    }
    let sortedLoud = loudDiff.sorted()
    let median = sortedLoud.isEmpty ? 0 : sortedLoud[sortedLoud.count / 2]
    let mad = sortedLoud.isEmpty ? 0 : sortedLoud.map { abs($0 - median) }.sorted()[sortedLoud.count / 2]
    let tSorted = times.sorted()
    print(String(format: "[analyze] n=%d · bpm ok %d (%.0f%%) + octave %d · key ok %d (%.0f%%) + related %d · grid ≤20 ms %d · loud offset median %+.2f dB, mad %.2f dB · time median %.1f s, max %.1f s",
                 n, bpmHits, 100 * Double(bpmHits) / Double(max(1, n)), bpmOctave, keyHits, 100 * Double(keyHits) / Double(max(1, n)), keyRelative,
                 gridHits, median, mad, tSorted.isEmpty ? 0 : tSorted[tSorted.count / 2], tSorted.last ?? 0))
}

/// MIX741_ANALYZE_FILE=<audio>: Zwischenstufen einer Datei drucken (Kamm-Kandidaten, Faltung, Chroma) – nur zum Nachsehen
@Test func analyzerDebugFile() throws {
    guard let path = ProcessInfo.processInfo.environment["MIX741_ANALYZE_FILE"] else { return }
    let d = try TrackAnalyzer.decode(url: URL(fileURLWithPath: path))
    let loud = d.stream.loudness()
    print("[dbg] rate \(d.rate) samples \(d.x.count) level \(loud.level) music \(loud.range)")
    let nov = try #require(TrackAnalyzer.novelty(d.x, rate: d.rate))
    let dbg = TrackAnalyzer.tempoDebug(nov, x: d.x, rate: d.rate, music: loud.range)
    print("[dbg] comb top: " + dbg.candidates.map { String(format: "%.2f:%.3f", $0.0, $0.1) }.joined(separator: " "))
    print("[dbg] fine \(dbg.fine) refined \(dbg.refined)")
    let o = TrackAnalyzer.onsets1k(d.x, rate: d.rate)
    let period = o.fs * 60 / dbg.refined
    if let f = TrackAnalyzer.fold(o, period: period, from: Int(loud.range.lowerBound * o.fs), to: min(o.v.count, Int((loud.range.lowerBound + 120) * o.fs))) {
        print(String(format: "[dbg] fold phase %.1f ms strength %.2f", f.phase / o.fs * 1000, f.strength))
    }
    if let prof = TrackAnalyzer.foldProfile(o, period: period, from: Int(loud.range.lowerBound * o.fs), to: min(o.v.count, Int((loud.range.lowerBound + 120) * o.fs))) {
        let m = prof.max() ?? 1
        let bins = prof.count
        print("[dbg] profile (" + String(bins) + " bins, % of max, every 8th): " + stride(from: 0, to: bins, by: 8).map { String(Int(prof[$0] / m * 100)) }.joined(separator: " "))
    }
    if let c = TrackAnalyzer.chroma(d.x, rate: d.rate) {
        let m = c.max() ?? 1
        print("[dbg] chroma C..B: " + c.map { String(format: "%.2f", $0 / m) }.joined(separator: " "))
        let k = TrackAnalyzer.key(chroma: c)
        print("[dbg] key \(k.map { Track.openKey(code: $0.code) } ?? "-") clarity \(k?.clarity ?? 0)")
    }
}
