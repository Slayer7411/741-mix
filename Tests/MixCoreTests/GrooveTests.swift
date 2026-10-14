import Foundation
import Testing
@testable import MixCore

/// synthetisches Spektrum: Grundrauschen je Band, Schläge als Leistung mit Abklingen
private struct Synth {
    let bps = 300.0, bpm = 128.0, anchor = 0.5
    var blocks: Int
    var power: [[Float]]          // [Band][Block] linear
    var sustain: [UInt8]

    init(seconds: Double = 20) {
        let n = Int(seconds * 300)
        blocks = n
        power = (0..<6).map { b in [Float](repeating: powf(10, (b < 2 ? -40 : -45) / 10), count: n) }
        sustain = [UInt8](repeating: 20, count: n)
    }
    var grid: BeatGrid { BeatGrid(anchor: anchor, bpm: bpm) }

    /// Schlag auf Beat `beat` (Grid), Pegel dB, Abklingzeit s
    mutating func hit(_ bands: [Int], beat: Double, db: Float, decay: Double, open: Bool = false) {
        let t = grid.time(ofBeat: beat), i0 = Int((t * bps).rounded())
        for i in i0..<min(blocks, i0 + Int(decay * 4 * bps)) where i >= 0 {
            let g = powf(10, db / 10) * Float(exp(-Double(i - i0) / bps / decay))
            for b in bands { power[b][i] += g }
            if open, bands.contains(4) { sustain[i] = 220 }
        }
    }

    var spectrum: WaveSpectrum {
        var d = [UInt8](repeating: 0, count: blocks * WaveSpectrum.stride)
        for i in 0..<blocks {
            for b in 0..<6 { d[i * WaveSpectrum.stride + b] = WaveSpectrum.byte(meanSquare: power[b][i]) }
            d[i * WaveSpectrum.stride + WaveSpectrum.sustainSlot] = sustain[i]
        }
        return WaveSpectrum(data: d)
    }
}

/// Track über 8 Takte: Kick auf jedem Beat, optional Clap auf 2 / 4, Hats auf den Offbeats (letzter offen)
private func techno(clap: Bool = false, hats: Bool = false) -> Synth {
    var s = Synth()
    for beat in 0..<32 {
        s.hit([0, 1], beat: Double(beat), db: -8, decay: 0.08)
        s.hit([3], beat: Double(beat), db: -30, decay: 0.01)   // Klick der Kick in den Mitten
        if clap, beat % 2 == 1 { s.hit([2, 3], beat: Double(beat), db: -14, decay: 0.05) }
        if hats {
            let open = beat % 4 == 3
            s.hit([4, 5], beat: Double(beat) + 0.5, db: open ? -16 : -18, decay: open ? 0.12 : 0.015, open: open)
        }
    }
    return s
}

@Test func grooveFindsKickOnEveryBeat() {
    let s = techno()
    let p = GrooveAnalyzer.extract(s.spectrum, blocksPerSecond: s.bps, grid: s.grid, startBeat: 8, beats: 8)
    #expect(p.steps == 32)
    #expect(p.steps(.kick) == [0, 4, 8, 12, 16, 20, 24, 28])
    #expect(p.steps(.snare).isEmpty)
    #expect(p.hatSteps.isEmpty)
}

@Test func grooveFindsClapAndHats() {
    let s = techno(clap: true, hats: true)
    let p = GrooveAnalyzer.extract(s.spectrum, blocksPerSecond: s.bps, grid: s.grid, startBeat: 4, beats: 8)
    #expect(p.steps(.kick) == [0, 4, 8, 12, 16, 20, 24, 28])
    #expect(p.steps(.snare) == [4, 12, 20, 28])
    #expect(p.steps(.closedHat) == [2, 6, 10, 18, 22, 26])
    #expect(p.steps(.openHat) == [14, 30])
    #expect(p.velocity(.kick, 0) > 60)
}

@Test func grooveWithoutSpectrumFallsBackToFourOnTheFloor() {
    let p = GrooveAnalyzer.extract(.empty, blocksPerSecond: 300, grid: BeatGrid(anchor: 0, bpm: 128), startBeat: 0, beats: 8)
    #expect(p.steps(.kick) == [0, 4, 8, 12, 16, 20, 24, 28])
}

private func options(_ i: GrooveInstrument, _ s: GrooveStyle, seed: UInt64, key: Int? = 21) -> GrooveGenerator.Options {
    var o = GrooveGenerator.Options()
    o.instrument = i; o.style = s; o.seed = seed; o.key = key
    return o
}

@Test func grooveHatsNeverDoubleTrackHats() {
    let s = techno(clap: true, hats: true)
    let p = GrooveAnalyzer.extract(s.spectrum, blocksPerSecond: s.bps, grid: s.grid, startBeat: 4, beats: 8)
    for style in GrooveStyle.allCases {
        for seed in 0..<20 as Range<UInt64> {
            let c = GrooveGenerator.clip(p, options(.hats, style, seed: seed))
            let steps = c.notes.map(\.step)
            #expect(!c.notes.isEmpty, "\(style) \(seed): keine Hats")
            #expect(Set(steps).count == steps.count, "\(style) \(seed): doppelt")
            #expect(Set(steps).isDisjoint(with: p.hatSteps), "\(style) \(seed): auf Track-Hats")
            #expect(c.notes.allSatisfy { $0.channel == 9 && ($0.note == 42 || $0.note == 46) && (0..<32).contains($0.step) })
        }
    }
    // ohne Hats im Track: tight = genau die Offbeats, off = offene Hat auf dem letzten Offbeat jedes Takts
    let kicks = GroovePattern.fourOnTheFloor(steps: 32)
    #expect(GrooveGenerator.hats(kicks, style: .tight, seed: 1).map(\.step) == [2, 6, 10, 14, 18, 22, 26, 30])
    let off = GrooveGenerator.hats(kicks, style: .off, seed: 1)
    #expect(off.filter(\.open).map(\.step).contains(14) && off.filter(\.open).map(\.step).contains(30))
    #expect(GrooveGenerator.hats(kicks, style: .rolling, seed: 1).count == 32)
}

@Test func grooveBassFollowsKeyAndKicks() {
    let p = GroovePattern.fourOnTheFloor(steps: 32)
    // Am (21) -> A, Oktave 1 (C3 = 60) -> 45
    #expect(GrooveGenerator.rootNote(key: 21, octave: 1) == 45)
    #expect(GrooveGenerator.rootNote(key: 0, octave: 2) == 48)
    #expect(GrooveGenerator.rootNote(key: 11, transpose: 2, octave: 1) == 37)   // B + 2 = C#
    #expect(GrooveGenerator.rootNote(key: nil, octave: 1) == 45)
    for style in GrooveStyle.allCases {
        for seed in 0..<20 as Range<UInt64> {
            let c = GrooveGenerator.clip(p, options(.bass, style, seed: seed))
            let steps = c.notes.map(\.step)
            #expect(!steps.isEmpty)
            #expect(Set(steps).count == steps.count)
            #expect(c.notes.allSatisfy { $0.channel == 0 && (0..<32).contains($0.step) && $0.length > 0 && $0.length <= 32 })
            // nur Grundton, Terz, Quinte, Oktave
            #expect(c.notes.allSatisfy { [0, 3, 7, 12].contains(Int($0.note) - 45) })
            #expect(c.notes.first?.note == 45, "erste Note = Grundton")
            switch style {
            case .tight: #expect(steps == [0, 4, 8, 12, 16, 20, 24, 28])
            case .off: #expect(steps.allSatisfy { $0 % 4 != 0 } && steps.filter { $0 % 4 == 2 }.count == 8)
            case .rolling: #expect(steps.allSatisfy { $0 % 4 != 0 } && steps.count >= 16)
            }
            // keine Überlappung: jede Note endet vor der nächsten
            for (a, b) in zip(c.notes, c.notes.dropFirst()) { #expect(Double(a.step) + a.length <= Double(b.step)) }
        }
    }
    // gleicher Seed = gleiches Ergebnis, anderer Seed variiert irgendwo
    let a = GrooveGenerator.clip(p, options(.both, .rolling, seed: 3)), b = GrooveGenerator.clip(p, options(.both, .rolling, seed: 3))
    #expect(a == b)
    let differs = (4..<30 as Range<UInt64>).contains { GrooveGenerator.clip(p, options(.both, .rolling, seed: $0)) != a }
    #expect(differs)
}

@Test func grooveMIDIFileRoundTrip() throws {
    let s = techno(clap: true, hats: true)
    let p = GrooveAnalyzer.extract(s.spectrum, blocksPerSecond: s.bps, grid: s.grid, startBeat: 4, beats: 8)
    let c = GrooveGenerator.clip(p, options(.both, .off, seed: 5))
    let data = MIDIFile.clip(c, bpm: 128, bassChannel: 0, repeats: 2)
    let f = try MIDIFile.parse(data)
    #expect(f.format == 1 && f.ppq == 480)
    #expect(f.tracks.count == 2)
    #expect(abs((f.bpm ?? 0) - 128) < 0.01)
    #expect(f.tracks[0].name.hasSuffix("Bass") && f.tracks[1].name.hasSuffix("Drums"))
    let bass = f.tracks[0].notes, drums = f.tracks[1].notes
    #expect(bass.count == c.notes(channel: 0).count * 2)
    #expect(drums.count == c.notes(channel: 9).count * 2)
    // Noten im Raster (120 Ticks je 16tel), Tonhöhe, Kanal, Velocity wie im Clip
    for (n, m) in zip(c.notes(channel: 0), bass) {
        #expect(m.tick == n.step * 120 && m.note == n.note && m.channel == 0 && m.velocity == n.velocity)
        #expect(m.length == Int((n.length * 120).rounded()))
    }
    #expect(drums.allSatisfy { $0.tick % 120 == 0 && $0.channel == 9 })
    #expect(drums.last.map { $0.tick >= 32 * 120 } == true)   // zweiter Durchlauf
    #expect(f.tracks.allSatisfy { $0.end == 2 * 32 * 120 })      // Spur-Ende = Loop-Länge
    #expect(throws: MIDIFile.ParseError.self) { try MIDIFile.parse(Data("MThd".utf8)) }
}

@Test func grooveScheduleOnTheClock() {
    var notes = [GrooveNote]()
    for s in stride(from: 2, to: 16, by: 4) { notes.append(GrooveNote(step: s, length: 1, channel: 9, note: 42, velocity: 100)) }
    var sch = GrooveSchedule(clip: GrooveClip(steps: 16, notes: notes), origin: 0)
    // Clock läuft in Schritten von 0,05 Beats über 8 Beats
    var all = [GrooveSchedule.Event]()
    var b = 100.0
    while b < 108 { all += sch.events(now: b, ahead: 0.1); b += 0.05 }
    let ons = all.filter(\.isOn), offs = all.filter { !$0.isOn }
    #expect(ons.map(\.beat) == [100.5, 101.5, 102.5, 103.5, 104.5, 105.5, 106.5, 107.5])
    #expect(offs.count == 8 && zip(ons, offs).allSatisfy { abs($1.beat - $0.beat - 0.25) < 1e-9 })
    // jedes Ereignis erst kurz vor seiner Zeit
    #expect(Set(ons.map(\.beat)).count == ons.count)
    // Sprung zurück: offene Note sofort beenden, ab dort neu
    var j = GrooveSchedule(clip: GrooveClip(steps: 16, notes: [GrooveNote(step: 0, length: 8, channel: 0, note: 45, velocity: 90)]), origin: 0)
    let first = j.events(now: 0, ahead: 0.1)
    #expect(first.count == 1 && first[0].isOn)
    let back = j.events(now: 40, ahead: 0.1)
    #expect(back.first.map { !$0.isOn && $0.beat == 40 } == true)
    #expect(back.filter(\.isOn).map(\.beat) == [40])
    #expect(j.flush(now: 41).count == 1)
}
