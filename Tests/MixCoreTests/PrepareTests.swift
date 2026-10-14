import Foundation
import Testing
@testable import MixCore

/// Vorbereiten: Amplify (Faktor, Spitze, NORM, Clipping-Schutz), Namen, JOIN-Plan, SPLIT, A-B-A über die Schnittliste
struct PrepareTests {
    @Test func amplifyFactorExact() {
        #expect(abs(Amplify.factor(db: 6) - 1.995_262_3) < 1e-6)
        #expect(abs(Amplify.factor(db: 3) - 1.412_537_5) < 1e-6)
        #expect(abs(Amplify.db(factor: 2) - 6.020_6) < 1e-4)
        // Samples × Faktor, genau die Float-Multiplikation (kein Limiter, keine Kurve)
        var x: [Float] = [0, 0.1, -0.25, 0.3333, -0.4999, 1e-6]
        let orig = x, f = Float(Amplify.factor(db: 3))
        x.withUnsafeMutableBufferPointer { Amplify.apply($0.baseAddress!, count: $0.count, factor: f, clamp: false) }
        #expect(x == orig.map { $0 * f })
        // Faktor 1 ohne Begrenzen: unverändert (Bit-genau)
        var y = orig
        y.withUnsafeMutableBufferPointer { Amplify.apply($0.baseAddress!, count: $0.count, factor: 1, clamp: false) }
        #expect(y == orig)
        // Clipping erlaubt: hart auf ±1
        var z: [Float] = [0.8, -0.9, 0.2]
        z.withUnsafeMutableBufferPointer { Amplify.apply($0.baseAddress!, count: $0.count, factor: 2, clamp: true) }
        #expect(z == [1, -1, 0.4])
    }

    @Test func peakHeadroomNorm() {
        let peak = Float(Amplify.factor(db: -4.2))
        #expect(abs(Amplify.dbfs(peak: peak) + 4.2) < 1e-5)
        #expect(abs(Amplify.headroom(peak: peak) - 4.2) < 1e-5)
        #expect(abs(Amplify.normGain(peak: peak) - 3.9) < 1e-5)   // -> −0.3 dBFS
        #expect(Amplify.dbfs(peak: 0) == -.infinity && Amplify.headroom(peak: 0) == .infinity && Amplify.normGain(peak: 0) == 0)
        #expect(AmpRequest.norm.gain(peak: peak) == Amplify.normGain(peak: peak))
        #expect(AmpRequest.norm.gain(peak: 1) == 0)   // schon über −0.3: NORM senkt nie
        #expect(AmpRequest.db(3).gain(peak: 1) == 3 && AmpRequest.db(0).isNone && !AmpRequest.norm.isNone)
    }

    /// Wunsch über den Headroom: begrenzt auf 0 dBFS (Warnung), mit Erlaubnis nicht; nie absenken
    @Test func clippingGuard() {
        let peak = Float(Amplify.factor(db: -4.2))
        let a = Amplify.limit(3, peak: peak, allowClipping: false)
        #expect(a.db == 3 && !a.limited)
        let b = Amplify.limit(6, peak: peak, allowClipping: false)
        #expect(abs(b.db - 4.2) < 1e-5 && b.limited)
        let c = Amplify.limit(6, peak: peak, allowClipping: true)
        #expect(c.db == 6 && !c.limited)
        #expect(Amplify.limit(-3, peak: peak, allowClipping: false).db == 0)
        #expect(Amplify.limit(12, peak: nil, allowClipping: false).db == 12)   // ungemessen: beim Rendern geprüft
        // sicherer Faktor: Spitze × Faktor ≤ 1 auch nach Float-Rundung
        for p in [Float(0.5), 0.70794576, 0.999, 0.123456] {
            let f = Amplify.safeFactor(Amplify.headroom(peak: p), peak: p)
            #expect(p * f <= 1 && p * f > 0.9999)
        }
    }

    @Test func loudnessFollowsGain() {
        var t = Track(key: "k", path: "/x.wav")
        t.perceivedDb = 2.5
        t.peakDb = 4.2
        Amplify.loudness(&t, gain: 3, peak: nil)
        #expect(abs(t.perceivedDb! + 0.5) < 1e-9 && abs(t.peakDb! - 1.2) < 1e-9)
        Amplify.loudness(&t, gain: 1, peak: Float(Amplify.factor(db: -0.3)))
        #expect(abs(t.peakDb! - 0.3) < 1e-5)
        #expect(Amplify.label(3) == "+3" && Amplify.label(4.25) == "+4.3" && Amplify.label(0) == "0" && Amplify.label(-1.5) == "−1.5")
    }

    @Test func names() {
        var taken: Set<String> = ["Track [amp +3].m4a"]
        #expect(PrepareName.fileName("Track.mp3", tag: "amp +3", taken: { taken.contains($0) }) == "Track [amp +3 #2].m4a")
        #expect(PrepareName.fileName("Track.wav", tag: "part 1", ext: "wav", taken: { _ in false }) == "Track [part 1].wav")
        taken = []
        #expect(PrepareName.joinName("A.flac", "B.mp3", taken: { taken.contains($0) }) == "A + B [join].m4a")
        #expect(PrepareName.renderTag(cut: false, gain: 3) == "amp +3")
        #expect(PrepareName.renderTag(cut: true, gain: 0) == "cut")
        #expect(PrepareName.renderTag(cut: true, gain: 4.2) == "cut amp +4.2")
        #expect(PrepareName.renderTag(cut: false, gain: 0) == nil)
        #expect(PrepareName.title("Song", tag: "join") == "Song [join]")
        let long = String(repeating: "x", count: 300) + ".wav"
        #expect(PrepareName.fileName(long, tag: "amp +1", taken: { _ in false }).utf8.count < 200)
    }

    /// JOIN: Naht am nächsten Taktanfang der ersten, zweite ab ihrer Beat-Eins, Tempo bis ±0,5 % angeglichen
    @Test func joinPlan() {
        let ga = BeatGrid(anchor: 0.1, bpm: 120)          // Takt = 2 s
        let gb = BeatGrid(anchor: 0.35, bpm: 120)
        var p = JoinPlan.plan(durationA: 61.0, gridA: ga, durationB: 30, gridB: gb, matchTempo: true)
        #expect(abs(p.joint - 62.1) < 1e-9)                  // Takte 0.1 + 2k: 60.1 < 61 -> 62.1
        #expect(abs(p.startB - 0.35) < 1e-9 && p.speed == 1 && !p.tempoMismatch)
        #expect(abs(p.duration - (62.1 + 29.65)) < 1e-9 && p.grid == ga)
        // Ende genau auf dem Takt (gerundet): kein Takt Stille
        p = JoinPlan.plan(durationA: 60.102, gridA: ga, durationB: 30, gridB: gb, matchTempo: true)
        #expect(abs(p.joint - 60.1) < 1e-9)
        // Anker mitten im Track: erste Beat-Eins der Datei
        p = JoinPlan.plan(durationA: 10, gridA: nil, durationB: 60, gridB: BeatGrid(anchor: 20.5, bpm: 120), matchTempo: true)
        #expect(abs(p.startB - 0.5) < 1e-9 && p.joint == 10 && p.grid == BeatGrid(anchor: 10, bpm: 120))
        // 0,4 % langsamer -> angeglichen, Beats der zweiten auf dem Grid der ersten
        let slow = BeatGrid(anchor: 0, bpm: 120 / 1.004)
        p = JoinPlan.plan(durationA: 8, gridA: BeatGrid(anchor: 0, bpm: 120), durationB: 20, gridB: slow, matchTempo: true)
        #expect(abs(p.speed - 1.004) < 1e-9 && !p.tempoMismatch)
        #expect(abs(p.outputTime(ofB: slow.time(ofBeat: 16)) - (8 + 16 * 0.5)) < 1e-9)
        #expect(JoinPlan.plan(durationA: 8, gridA: BeatGrid(anchor: 0, bpm: 120), durationB: 20, gridB: slow, matchTempo: false).speed == 1)
        // 2 % -> nicht angeglichen, Hinweis
        p = JoinPlan.plan(durationA: 8, gridA: BeatGrid(anchor: 0, bpm: 120), durationB: 20, gridB: BeatGrid(anchor: 0, bpm: 122.4), matchTempo: true)
        #expect(p.speed == 1 && p.tempoMismatch)
    }

    @Test func joinCuesShifted() {
        let p = JoinPlan.plan(durationA: 61, gridA: BeatGrid(anchor: 0.1, bpm: 120), durationB: 30, gridB: BeatGrid(anchor: 0.35, bpm: 120),
                              matchTempo: true)
        let a = [Cue(name: "In", kind: .cue, startMs: 100, lengthMs: 0, hotcue: 0),
                 Cue(name: "Grid", kind: .grid, startMs: 100, lengthMs: 0, hotcue: -1),
                 Cue(name: "Drop", kind: .cue, startMs: 30_000, lengthMs: 0, hotcue: 2)]
        let b = [Cue(name: "B1", kind: .cue, startMs: 350, lengthMs: 0, hotcue: 0),
                 Cue(name: "Pre", kind: .cue, startMs: 100, lengthMs: 0, hotcue: 1),       // vor der Beat-Eins: weg
                 Cue(name: "Loop", kind: .loop, startMs: 8_350, lengthMs: 8_000, hotcue: 3),
                 Cue(name: "Mem", kind: .cue, startMs: 10_350, lengthMs: 0, hotcue: -1)]
        let c = p.cues(a: a, b: b)
        #expect(c.count == 5 && !c.contains { $0.kind == .grid } && !c.contains { $0.name == "Pre" })
        let b1 = c.first { $0.name == "B1" }!
        #expect(abs(b1.startMs - 62_100) < 1e-6 && b1.hotcue == 1)     // Platz 1 belegt -> nächster freier
        let loop = c.first { $0.name == "Loop" }!
        #expect(abs(loop.startMs - 70_100) < 1e-6 && loop.lengthMs == 8_000 && loop.hotcue == 3)
        #expect(abs(c.first { $0.name == "Mem" }!.startMs - 72_100) < 1e-6)
        var ta = Track(key: "a", path: "/a.wav"); ta.title = "A"; ta.bpm = 120
        var tb = Track(key: "b", path: "/b.wav"); tb.title = "B"
        let t = p.track(a: ta, b: tb, key: "n", path: "/n.m4a", cuesA: a, cuesB: b, duration: p.duration)
        #expect(t.title == "A + B [join]" && t.gridAnchorMs == 100 && t.bpm == 120 && t.cues.count == 6 && abs(t.duration - 91.75) < 1e-9)
    }

    /// SPLIT: Teilungspunkt am Takt, Teile der Schnittliste, Grid von Teil 2 ab 0 auf Takt-Eins
    @Test func split() {
        let g = BeatGrid(anchor: 0.25, bpm: 128)
        let bar = 4 * g.beat
        let t = SplitPlan.point(range: nil, position: 0.25 + 10.2 * bar, grid: g, duration: 120)!
        #expect(abs(t - (0.25 + 10 * bar)) < 1e-9)
        #expect(SplitPlan.point(range: TrackRange(30, 40), position: 5, grid: g, duration: 120) == 30)
        #expect(SplitPlan.point(range: nil, position: 0.1, grid: nil, duration: 120) == nil)    // Teil 1 zu kurz
        let e = EditList(duration: 120)
        let (a, b) = SplitPlan.parts(e, at: t)!
        #expect(abs(a.duration - t) < 1e-9 && abs(b.duration - (120 - t)) < 1e-9)
        #expect(abs(a.duration + b.duration - 120) < 1e-9)
        #expect(a.grid(g) == g)
        #expect(abs(b.grid(g).anchor) < 1e-9 && b.grid(g).bpm == 128)
        // Cues verteilt
        let cues = [Cue(name: "x", kind: .cue, startMs: 5_000, lengthMs: 0, hotcue: 0), Cue(name: "y", kind: .cue, startMs: 40_000, lengthMs: 0, hotcue: 1)]
        #expect(a.cues(cues).map(\.name) == ["x"] && b.cues(cues).map(\.name) == ["y"])
        #expect(abs(b.cues(cues)[0].startMs - (40 - t) * 1000) < 1e-6)
        #expect(SplitPlan.tag(2) == "part 2")
    }

    /// A-B-A: B (am Grid) aus der Schnittliste, A und A schließen an; Grid dahinter bleibt auf dem Raster
    @Test func abaOverEditList() {
        let g = BeatGrid(anchor: 0.5, bpm: 120)   // Beat 0.5 s
        var e = EditList(duration: 180)
        let b = TrackRange(g.time(ofBeat: 64), g.time(ofBeat: 96))   // 16 s
        let removed = e.remove(b)
        #expect(removed)
        #expect(abs(e.duration - 164) < 1e-9 && e.audible.count == 2 && e.isCut(joint: 0))
        #expect(e.grid(g) == g)
        // Beat 100 der Quelle liegt nach der Naht wieder auf einem Beat des Grids
        let out = e.outputTime(g.time(ofBeat: 100))!
        #expect(abs(g.beatPosition(at: out) - 68) < 1e-9)
        // Frames: Länge = A + A' sample-genau
        let f = e.frames(rate: 44_100, sourceFrames: 180 * 44_100)
        #expect(f.pieces.reduce(0) { $0 + $1.count } == 164 * 44_100)
        let cues = [Cue(name: "in B", kind: .cue, startMs: 40_000, lengthMs: 0, hotcue: 0),
                    Cue(name: "after", kind: .cue, startMs: 60_000, lengthMs: 0, hotcue: 1)]
        #expect(e.cues(cues).map(\.name) == ["after"] && abs(e.cues(cues)[0].startMs - 44_000) < 1e-6)
    }
}
