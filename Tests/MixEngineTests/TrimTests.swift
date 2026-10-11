import Foundation
import Testing
import MixDSP

/// Schnitt im Kern offline: Track 10 s, Schnitt 2–8 s. `leak`: außerhalb lauter Sinus, innen Stille -> jedes Sample am
/// Ausgang über 0 käme aus dem weggeschnittenen Teil. Sonst innen laut, außen still.
private final class Trimmed {
    let e: OpaquePointer
    let fs = 44100.0
    let frames: Int
    let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    /// größter Betrag am Ausgang (Kanal 1/2) seit dem letzten Zurücksetzen
    var maxOut: Float = 0
    var first: [Float] = []

    init(leak: Bool, trim: (Double, Double)? = (2, 8), seconds: Double = 10) {
        e = mdsp_create(fs)
        frames = Int(seconds * fs)
        left = .allocate(capacity: frames); right = .allocate(capacity: frames)
        for i in 0..<frames {
            let t = Double(i) / fs, inside = t >= 2 && t < 8
            let v = inside != leak ? Float(sin(2 * .pi * 220 * t)) * 0.5 : 0
            left[i] = v; right[i] = v
        }
        if let trim { mdsp_set_trim(e, 0, trim.0, trim.1) }
        mdsp_set_track(e, 0, left, right, Int64(frames), fs, 0)
        render(512)
    }
    deinit { mdsp_destroy(e); left.deallocate(); right.deallocate() }

    func set(_ p: MDParam, _ v: Float) { mdsp_set_param(e, 0, p, v) }
    func seek(_ s: Double) { mdsp_seek(e, 0, s) }
    var position: Double { mdsp_position(e, 0) }
    var playing: Bool { mdsp_playing(e, 0) }

    /// Block rendern, RMS links
    @discardableResult
    func render(_ n: Int) -> Float {
        var l = [Float](repeating: 0, count: n), r = [Float](repeating: 0, count: n)
        var sum: Float = 0
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var ch: [UnsafeMutablePointer<Float>?] = [lp.baseAddress, rp.baseAddress]
                ch.withUnsafeMutableBufferPointer { mdsp_render(e, $0.baseAddress, 2, Int32(n)) }
            }
        }
        for i in 0..<n { maxOut = max(maxOut, abs(l[i]), abs(r[i])); sum += l[i] * l[i] }
        if first.isEmpty { first = l }
        return (sum / Float(n)).squareRoot()
    }

    @discardableResult
    func render(seconds: Double) -> Float {
        let blocks = max(1, Int(seconds * fs / 512))
        var acc: Float = 0
        for _ in 0..<blocks { acc += render(512) }
        return acc / Float(blocks)
    }
}

/// vorwärts ins Ende: Stopp am Schnitt-Ende wie am Track-Ende, nichts dahinter hörbar (Varispeed und Keylock)
@Test func trimPlaysIntoTheEndAndStops() {
    for keylock: Float in [0, 1] {
        let c = Trimmed(leak: true)
        c.set(MD_KEYLOCK, keylock)
        c.seek(7.5); c.render(512)
        c.maxOut = 0
        c.set(MD_PLAYING, 1)
        c.render(seconds: 1.5)
        #expect(!c.playing, "keylock \(keylock)")
        #expect(abs(c.position - 8) < 0.01, "keylock \(keylock): \(c.position)")
        #expect(c.maxOut < 1e-4, "keylock \(keylock): \(c.maxOut)")
    }
}

/// innen wird gespielt, auch mit Keylock bis kurz vor das Ende
@Test func trimPlaysInside() {
    for keylock: Float in [0, 1] {
        let c = Trimmed(leak: false)
        c.set(MD_KEYLOCK, keylock)
        c.seek(6); c.render(512)
        c.set(MD_PLAYING, 1)
        #expect(c.render(seconds: 1.5) > 0.15, "keylock \(keylock)")
        #expect(c.playing && c.position > 7.4 && c.position < 8, "keylock \(keylock): \(c.position)")
    }
}

/// Sprünge vor den Start / hinter das Ende landen auf der Grenze, sofort sichtbar
@Test func seekOutsideTrimLandsOnItsBounds() {
    let c = Trimmed(leak: true)
    #expect(abs(c.position - 2) < 1e-9)           // Ladeposition 0 -> Schnitt-Start
    c.seek(0.5)
    #expect(c.position == 2)
    c.render(512)
    #expect(c.position == 2)
    c.seek(9.5)
    #expect(c.position == 8)
    c.maxOut = 0
    c.set(MD_PLAYING, 1)
    c.render(seconds: 0.2)
    #expect(!c.playing && c.position == 8 && c.maxOut < 1e-4)
}

/// Loop über das Schnitt-Ende: läuft nur bis zum Ende und springt dort zurück, Deck spielt weiter
@Test func loopOverTrimEndWrapsAtTheEnd() {
    for keylock: Float in [0, 1] {
        let c = Trimmed(leak: true)
        c.set(MD_KEYLOCK, keylock)
        c.seek(7.4); c.render(512)
        mdsp_set_loop(c.e, 0, true, 7.5, 8.5)
        c.maxOut = 0
        c.set(MD_PLAYING, 1)
        var inside = true
        for _ in 0..<Int(2 * c.fs / 512) {
            c.render(512)
            inside = inside && c.position >= 7.3 && c.position <= 8.0
        }
        #expect(c.playing && inside, "keylock \(keylock)")
        #expect(c.maxOut < 1e-4, "keylock \(keylock): \(c.maxOut)")
    }
}

/// rückwärts an den Start: bleibt dort stehen, nichts davor hörbar
@Test func reverseStopsAtTrimStart() {
    for keylock: Float in [0, 1] {
        let c = Trimmed(leak: true)
        c.set(MD_KEYLOCK, keylock)
        c.seek(2.5); c.render(512)
        c.maxOut = 0
        c.set(MD_REVERSE, 1); c.set(MD_PLAYING, 1)
        c.render(seconds: 1.5)
        let tol = keylock == 1 ? 0.2 : 0.01   // Keylock: Lesekopf steht am Start, hörbar ist er um die Latenz davor
        #expect(c.position >= 2 && c.position - 2 < tol, "keylock \(keylock): \(c.position)")
        #expect(c.maxOut < 1e-4, "keylock \(keylock): \(c.maxOut)")
    }
}

/// Schnitt ändert sich während des Spielens: Position springt in den Schnitt
@Test func trimChangeMovesThePlayhead() {
    let c = Trimmed(leak: false, trim: nil)
    c.seek(5); c.render(512)
    c.set(MD_PLAYING, 1); c.render(seconds: 0.2)
    mdsp_set_trim(c.e, 0, 6, 8)
    #expect(c.position < 6)
    c.render(512)
    #expect(c.position >= 6 && c.position < 6.05)
    // mit Keylock
    mdsp_set_trim(c.e, 0, 0, 0)
    c.set(MD_KEYLOCK, 1); c.seek(3); c.render(seconds: 0.3)
    mdsp_set_trim(c.e, 0, 4, 8)
    c.render(512)
    #expect(c.position >= 4 && c.position < 4.05, "\(c.position)")
}

/// geschnittener Rand blendet kurz ein (kein Knacken): Sprung auf einen Start mitten im Sinus bei vollem Pegel
@Test func trimStartFadesIn() {
    let c = Trimmed(leak: false, trim: nil)
    c.seek(4); c.render(512)
    c.set(MD_PLAYING, 1); c.render(seconds: 0.2)
    mdsp_set_trim(c.e, 0, 4.5003, 8)   // Sinus dort bei ~0,4 -> ohne Rampe ein Sprung auf ~0,17
    c.first = []
    c.render(512)
    #expect(c.first.prefix(16).allSatisfy { abs($0) < 0.05 }, "\(c.first.prefix(16))")
    #expect(c.render(seconds: 0.2) > 0.2)
}

/// Ende <= Start = kein Schnitt; nur Start = bis zum Track-Ende
@Test func invalidOrOpenTrim() {
    let c = Trimmed(leak: false, trim: (5, 4))
    c.seek(1)
    #expect(c.position == 1)
    mdsp_set_trim(c.e, 0, 3, 0)
    c.seek(1)
    #expect(c.position == 3)
    c.seek(9.9); c.render(512)
    c.set(MD_PLAYING, 1); c.render(seconds: 0.3)
    #expect(!c.playing && abs(c.position - 10) < 0.01)
    mdsp_set_trim(c.e, 0, .nan, 4)                  // nicht endlich: verworfen, Schnitt bleibt
    c.seek(1)
    #expect(c.position == 3)
}
