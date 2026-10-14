import Foundation
import Testing
import MixCore
@testable import MixEngine

private let rate = 44100.0
private let cMajor = [130.81, 164.81, 196.0, 261.63, 329.63, 392.0]
private let fsMajor = [185.0, 233.08, 277.18, 369.99, 466.16, 554.37]

/// Stück: Kick (55 Hz) je Beat, Hat auf dem Offbeat, Akkord-Fläche; ohne `beat` nur die Fläche, ohne `pad` nur Schläge
private func piece(bpm: Double, seconds: Double, chord: [Double], beat: Bool = true, pad: Bool = true) -> [Float] {
    let n = Int(seconds * rate)
    var x = [Float](repeating: 0, count: n)
    if beat {
        let period = 60 / bpm
        var k = 0
        while Double(k) * period < seconds {
            let s0 = Int(Double(k) * period * rate)
            for i in 0..<Int(0.25 * rate) where s0 + i < n {
                let t = Double(i) / rate
                x[s0 + i] += 0.6 * Float(sin(2 * .pi * 55 * t) * exp(-t / 0.09))
            }
            let sh = Int((Double(k) + 0.5) * period * rate)
            for i in 0..<Int(0.02 * rate) where sh + i < n {
                let t = Double(i) / rate
                x[sh + i] += 0.15 * Float(sin(2 * .pi * 6000 * t) * exp(-t / 0.006))
            }
            k += 1
        }
    }
    if pad {
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.0
            for f in chord { v += sin(2 * .pi * f * t) + 0.4 * sin(2 * .pi * 2 * f * t) }
            x[i] += Float(0.04 * v)
        }
    }
    return x
}

private func silence(_ s: Double) -> [Float] { [Float](repeating: 0, count: Int(s * rate)) }

private func run(_ x: [Float], grid: Bool = true) throws -> (RipCheck.Result, TrackAnalyzer.Result) {
    try x.withUnsafeBufferPointer { p in
        let a = try TrackAnalyzer.analyze(left: p.baseAddress!, right: p.baseAddress!, frames: p.count, sampleRate: rate)
        let r = try RipCheck.check(left: p.baseAddress!, right: p.baseAddress!, frames: p.count, sampleRate: rate,
                                   bpm: grid ? a.bpm : 0, anchor: a.anchor)
        return (r, a)
    }
}

/// 6,3 s Stille vorne: Schnitt IN auf dem Beat vor dem ersten Schlag, sonst nichts
@Test func ripLateStart() throws {
    let (r, a) = try run(silence(6.3) + piece(bpm: 128, seconds: 70, chord: cMajor))
    let s = try #require(r.start, "\(r.findings)")
    #expect(s.kind == .silence)
    #expect(s.time <= 6.3 + 0.01 && s.time > 6.3 - 60 / a.bpm, "\(s.time)")
    #expect(r.end == nil, "\(r.findings)")
}

/// 4 Takte Track A (128 BPM, C) hart geschnitten vor Track B (126 BPM, Fis): Befund am ersten Beat von B
@Test func ripForeignStart() throws {
    let (r, a) = try run(piece(bpm: 128, seconds: 7.5, chord: cMajor) + piece(bpm: 126, seconds: 90, chord: fsMajor))
    #expect(abs(a.bpm - 126) < 0.1)
    let s = try #require(r.start, "\(r.findings)")
    #expect(s.kind == .foreign)
    #expect(abs(s.time - 7.5) < 0.03, "\(s.time)")
    #expect(s.cues.contains(.key))
    #expect(s.keyTrack == 6 && s.keyForeign != nil && s.keyForeign != 6, "\(String(describing: s.keyForeign)) \(String(describing: s.keyTrack))")
    #expect(s.bars == 4, "\(String(describing: s.bars))")
    #expect(s.confidence >= 0.6)
    #expect(r.end == nil, "\(r.findings)")
}

/// fremder Loop über 8 Takte: Loop-Hinweis (4 Takte); ohne Grid Schnitt nahe am Bruch
@Test func ripForeignLoopAndNoGrid() throws {
    let x = piece(bpm: 128, seconds: 15, chord: cMajor) + piece(bpm: 126, seconds: 90, chord: fsMajor)
    let (r, _) = try run(x)
    let s = try #require(r.start, "\(r.findings)")
    #expect(s.kind == .foreign && abs(s.time - 15) < 0.03, "\(s.time)")
    #expect(s.cues.contains(.loop) && s.bars == 4, "\(s.cues) \(String(describing: s.bars))")
    let (n, _) = try run(x, grid: false)
    let t = try #require(n.start, "\(n.findings)")
    #expect(abs(t.time - 15) < 0.1, "\(t.time)")
    #expect(n.grid == nil)
}

/// Breakdown-Intro ohne Beat (30 s Fläche, gleiche Tonart), dann Beat: kein Befund
@Test func ripBreakdownIntroIsNoFinding() throws {
    let (r, _) = try run(piece(bpm: 128, seconds: 30, chord: cMajor, beat: false) + piece(bpm: 128, seconds: 70, chord: cMajor))
    #expect(r.start == nil && r.end == nil, "\(r.findings)")
}

/// Intro nur Schläge (16 Takte), dann Fläche: kein Befund (Kick allein ist nicht tonal, Tempo gleich)
@Test func ripDrumIntroIsNoFinding() throws {
    let (r, _) = try run(piece(bpm: 128, seconds: 30, chord: cMajor, pad: false) + piece(bpm: 128, seconds: 70, chord: cMajor))
    #expect(r.start == nil && r.end == nil, "\(r.findings)")
}

/// 8 s Stille hinten: Schnitt OUT auf dem Beat nach dem Ende; 4 s Ausklang sind kein Befund
@Test func ripSilenceAtEnd() throws {
    let (short, _) = try run(piece(bpm: 128, seconds: 70, chord: cMajor) + silence(4))
    #expect(short.end == nil, "\(short.findings)")
    let (r, a) = try run(piece(bpm: 128, seconds: 70, chord: cMajor) + silence(8))
    let e = try #require(r.end, "\(r.findings)")
    #expect(e.kind == .silence)
    #expect(e.time >= 70 - 0.01 && e.time < 70 + 60 / a.bpm + 0.3, "\(e.time)")
    #expect(r.start == nil)
}

/// Ende mit dem Anfang des nächsten Tracks (8 s, 128 BPM, C): Schnitt OUT am Bruch
@Test func ripForeignEnd() throws {
    let (r, _) = try run(piece(bpm: 126, seconds: 90, chord: fsMajor) + piece(bpm: 128, seconds: 8, chord: cMajor))
    let e = try #require(r.end, "\(r.findings)")
    #expect(e.kind == .foreign)
    #expect(abs(e.time - 90) < 0.03, "\(e.time)")
    #expect(r.start == nil, "\(r.findings)")
}

/// sauberer Track: nichts
@Test func ripCleanTrack() throws {
    let (r, _) = try run(piece(bpm: 124, seconds: 80, chord: cMajor))
    #expect(r.findings.isEmpty, "\(r.findings)")
}

/// echte Tracks (nur lesen): `MIX741_RIP_NML=<collection.nml> MIX741_RIP_N=40 swift test --filter ripAgainstCollection`
/// -> Befunde je Track und Laufzeit, zum Nachhören
@Test func ripAgainstCollection() throws {
    guard let nml = ProcessInfo.processInfo.environment["MIX741_RIP_NML"] else { return }
    let want = Int(ProcessInfo.processInfo.environment["MIX741_RIP_N"] ?? "") ?? 40
    let all = try NMLParser.parse(url: URL(fileURLWithPath: nml)).tracks
    let eligible = all.filter { $0.bpm > 0 && $0.gridAnchorMs != nil && $0.duration > 60 && OverviewPolicy.fileState(path: $0.path) == .local }
    let step = max(1, eligible.count / want)
    var times: [Double] = [], checks: [Double] = [], hits = 0
    for t in stride(from: 0, to: eligible.count, by: step).prefix(want).map({ eligible[$0] }) {
        let t0 = Date()
        guard let st = try? TrackAnalyzer.decode(url: URL(fileURLWithPath: t.path)) else { continue }
        let t1 = Date()
        guard let r = try? RipCheck.check(stream: st, bpm: t.bpm, anchor: t.gridAnchorMs! / 1000, params: RipCheck.Params(), checkpoint: {}) else { continue }
        times.append(Date().timeIntervalSince(t0))
        checks.append(Date().timeIntervalSince(t1))
        if !r.findings.isEmpty { hits += 1 }
        let f = r.findings.map { f in
            "\(f.id) \(String(format: "%.2f", f.time)) c\(String(format: "%.2f", f.confidence)) \(f.cues.map(\.rawValue).joined(separator: "+"))"
                + (f.keyForeign.map { " k\($0)->\(f.keyTrack ?? -1)" } ?? "") + (f.bars.map { " \($0)bars" } ?? "")
                + (f.offsetMs.map { String(format: " %+.0fms", $0) } ?? "") + (f.localBPM.map { String(format: " %.1fbpm", $0) } ?? "")
        }
        print(String(format: "[rip] %.1fs %@ – %@ (%.0f s, %.2f bpm): %@", times.last!, t.artist, t.title, t.duration, t.bpm,
                     f.isEmpty ? "-" : f.joined(separator: " | ")))
    }
    let sorted = times.sorted()
    let cs = checks.sorted()
    print(String(format: "[rip] %d tracks, %d with findings, median %.2f s per track (check alone %.2f s)", times.count, hits,
                 sorted.isEmpty ? 0 : sorted[sorted.count / 2], cs.isEmpty ? 0 : cs[cs.count / 2]))
}
