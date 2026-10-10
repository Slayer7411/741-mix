import Testing
@testable import MixCore

/// Kern meldet alle `block` s, Bilder alle `frame` s: Bewegung je Bild (s)
private func run(_ s: inout PlayheadSmoother, from: Double, frames: Int, frame: Double, block: Double, speed: Double = 1,
                 t0: Double = 0, pos0: Double = 10) -> [Double] {
    var moves: [Double] = [], last = Double.nan
    for i in 0..<frames {
        let t = t0 + Double(i) * frame
        let raw = pos0 + speed * (t / block).rounded(.down) * block
        let p = s.update(raw: raw, speed: speed, at: t)
        if !last.isNaN { moves.append(p - last) }
        last = p
    }
    return moves
}

@Test func smootherEvenSteps() {
    // 120 Hz, Blöcke 10.67 ms: roh 0 / 1 / 2 Blöcke je Bild, geglättet gleichmäßig
    var s = PlayheadSmoother()
    let frame = 1.0 / 120, block = 512.0 / 48000
    let moves = run(&s, from: 10, frames: 240, frame: frame, block: block).dropFirst(60)
    let lo = moves.min()!, hi = moves.max()!
    #expect(lo > frame * 0.75)
    #expect(hi < frame * 1.25)
    // mittlere Geschwindigkeit stimmt
    #expect(abs(moves.reduce(0, +) / Double(moves.count) - frame) < frame * 0.02)
}

@Test func smootherSixtyHz() {
    var s = PlayheadSmoother()
    let frame = 1.0 / 60, block = 1024.0 / 44100
    let moves = run(&s, from: 10, frames: 180, frame: frame, block: block).dropFirst(60)
    #expect(moves.min()! > frame * 0.75)
    #expect(moves.max()! < frame * 1.25)
}

@Test func smootherStopsAtReported() {
    var s = PlayheadSmoother()
    let frame = 1.0 / 120, block = 512.0 / 48000
    _ = run(&s, from: 10, frames: 120, frame: frame, block: block)
    // Kern steht (Position bleibt), Geschwindigkeit noch nicht nachgezogen: höchstens ein Abstand über, dann genau
    let stop = 10 + (119 * frame / block).rounded(.down) * block
    var p = 0.0
    for i in 120..<160 { p = s.update(raw: stop, speed: 1, at: Double(i) * frame) }
    #expect(p == stop)
    #expect(s.update(raw: stop, speed: 0, at: 160 * frame) == stop)
}

@Test func smootherJumps() {
    var s = PlayheadSmoother()
    let frame = 1.0 / 120, block = 512.0 / 48000
    _ = run(&s, from: 10, frames: 120, frame: frame, block: block)
    let t = 120 * frame
    // Beatjump 1/4 Beat bei 128 BPM vor und zurück, Loop-Ende zurück: sofort übernommen
    #expect(s.update(raw: 11 + 0.117, speed: 1, at: t) == 11 + 0.117)
    #expect(s.update(raw: 11 - 0.117, speed: 1, at: t + frame) == 11 - 0.117)
    // rückwärts abspielen
    var r = PlayheadSmoother()
    let moves = run(&r, from: 10, frames: 240, frame: frame, block: block, speed: -1).dropFirst(60)
    #expect(moves.max()! < -frame * 0.75)
    #expect(moves.min()! > -frame * 1.25)
}

@Test func smootherStandingDeck() {
    var s = PlayheadSmoother()
    #expect(s.update(raw: 5, speed: 0, at: 0) == 5)
    #expect(s.update(raw: 5.5, speed: 0, at: 0.01) == 5.5)   // Seek im Stand
    #expect(s.update(raw: 5.5, speed: 1, at: 0.02) == 5.5)   // erstes Bild nach Play: gemeldete Position
}
