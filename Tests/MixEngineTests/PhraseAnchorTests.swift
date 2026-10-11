import CoreGraphics
import Foundation
import ImageIO
import Testing
import MixCore
@testable import MixMedia
import MixEngine

/// Synthetischer Track: Kick auf jedem Beat, ab Takt 9 wechseln alle 8 Takte Hi-Hat, Bass und ein Breakdown
/// (Takt 33–40 ohne Kick, mit Fläche). Echter Taktanfang bei `start` Sekunden, 128 BPM.
private final class Synth: @unchecked Sendable {
    let fs = 44100.0, bpm = 128.0, start = 0.5
    let frames: Int
    let left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>
    var beat: Double { 60 / bpm }

    init(bars: Int = 72, noiseOnly: Bool = false) {
        frames = Int((start + Double(bars * 4) * 60 / bpm + 2) * fs)
        left = .allocate(capacity: frames); right = .allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames)
        var seed: UInt64 = 0x741
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        if noiseOnly {
            for i in 0..<frames { left[i] = rnd() * 0.3 }
        } else {
            let beat = 60 / bpm
            for n in 0..<(bars * 4) {
                let bar = n / 4 + 1   // 1-basiert
                let section = (bar - 1) / 8   // 0 = Takt 1–8, 1 = 9–16, …
                let breakdown = section == 4
                let t0 = start + Double(n) * beat
                let i0 = Int(t0 * fs)
                if !breakdown {   // Kick: Sinus 110 → 45 Hz, kurz
                    var ph = 0.0
                    for k in 0..<Int(0.2 * fs) where i0 + k < frames {
                        let t = Double(k) / fs
                        ph += 2 * .pi * (45 + 65 * exp(-t / 0.03)) / fs
                        left[i0 + k] += Float(sin(ph) * exp(-t / 0.09)) * 0.8
                    }
                }
                let off = Int((t0 + beat / 2) * fs)
                if section % 2 == 1 {   // Hi-Hat auf der Offbeat-Achtel (Rauschen, hochpassig)
                    var prev: Float = 0
                    for k in 0..<Int(0.05 * fs) where off + k < frames {
                        let x = rnd(); let h = x - prev; prev = x
                        left[off + k] += h * Float(exp(-Double(k) / fs / 0.012)) * 0.25
                    }
                }
                if section >= 2, section % 4 >= 2 || section >= 6 {   // Bass auf dem Offbeat
                    for k in 0..<Int(beat / 2 * fs) where off + k < frames {
                        let t = Double(k) / fs
                        left[off + k] += Float(sin(2 * .pi * 55 * t) * min(1, t / 0.01) * exp(-t / 0.15)) * 0.5
                    }
                }
                if breakdown {   // Fläche
                    for k in 0..<Int(beat * fs) where i0 + k < frames {
                        let t = Double(i0 + k) / fs
                        left[i0 + k] += Float(sin(2 * .pi * 311 * t) + sin(2 * .pi * 466 * t)) * 0.15
                    }
                }
            }
        }
        right.update(from: left, count: frames)
    }
    deinit { left.deallocate(); right.deallocate() }

    func analyze(anchorBeats: Double) -> PhraseAnchor.Result {
        PhraseAnchor.analyze(left: left, right: right, frames: frames, sampleRate: fs,
                             grid: BeatGrid(anchor: start + anchorBeats * beat, bpm: bpm))
    }
}

@Suite struct PhraseAnchorTests {
    private static let track = Synth()

    @Test func anchorCorrect() {
        let r = Self.track.analyze(anchorBeats: 0)
        #expect(r.shiftBeats == 0)
        #expect(!r.suggests)
    }

    @Test(arguments: [1, 3, 4, -1, 8])
    func anchorLate(_ late: Int) {
        let r = Self.track.analyze(anchorBeats: Double(late))
        #expect(r.shiftBeats == -late, "Anker \(late) Beats daneben: \(r)")
        #expect(r.confidence >= PhraseAnchor.threshold)
        #expect(r.suggests)
    }

    @Test func noise() {
        let n = Synth(noiseOnly: true)
        let r = n.analyze(anchorBeats: 0)
        #expect(!r.suggests, "\(r)")
    }

    /// verschobener Anker → analysieren → Vorschlag anwenden → erneut analysieren: 0
    @Test func applyIsStable() {
        let r = Self.track.analyze(anchorBeats: 3)
        let again = Self.track.analyze(anchorBeats: 3 + Double(r.shiftBeats))
        #expect(again.shiftBeats == 0)
    }
}

/// Echte Daten (nur mit MIX741_NML=<collection.nml>, nur lesend): die ersten 30 Tracks mit 120–140 BPM, Grid und Datei
/// analysieren und je Track Verschiebung und Sicherheit ausgeben
@Test(.enabled(if: ProcessInfo.processInfo.environment["MIX741_NML"] != nil))
func phraseAnchorRealData() throws {
    let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MIX741_NML"]!)
    let limit = Int(ProcessInfo.processInfo.environment["MIX741_PHRASE_N"] ?? "") ?? 30
    let tracks = try NMLParser.parse(url: url).tracks
        .filter { $0.bpm > 120 && $0.bpm < 140 && $0.gridAnchorMs != nil && FileManager.default.fileExists(atPath: $0.path) }
        .prefix(limit)
    var hist: [String: Int] = [:]
    for t in tracks {
        guard let g = BeatGrid(track: t) else { continue }
        let t0 = Date()
        guard let a = try? TrackAudio.decode(url: URL(fileURLWithPath: t.path), sampleRate: 44100) else { print("[phrase] decode failed: \(t.fileName)"); continue }
        let t1 = Date()
        let r = PhraseAnchor.analyze(a, grid: g)
        let dt = Date().timeIntervalSince(t1)
        if let q = ProcessInfo.processInfo.environment["MIX741_PHRASE_DEBUG"], t.title.localizedCaseInsensitiveContains(q) || q == "*",
           let f = PhraseAnchor.beatFeatures(left: a.left, right: a.right, frames: a.frames, sampleRate: a.sampleRate, grid: g) {
            if let dir = ProcessInfo.processInfo.environment["MIX741_PHRASE_PNG"] {
                let r0 = PhraseAnchor.analyze(a, grid: g)
                plot(f.features, firstBeat: f.firstBeat, shift: r0.shiftBeats,
                     to: URL(fileURLWithPath: dir).appendingPathComponent("\(t.title.prefix(20)).png"))
            }
            print("[phrase-debug] \(t.title) firstBeat \(f.firstBeat) start \(f.start) end \(f.end)")
            for b in PhraseAnchor.boundaries(f.features, from: f.start, to: f.end) {
                let n = b.index + f.firstBeat
                if ProcessInfo.processInfo.environment["MIX741_PHRASE_DUMP"] != nil {
                    for i in max(0, b.index - 6)...min(f.features.count - 1, b.index + 4) {
                        print("[phrase-debug]      " + String(format: "%4d ", i + f.firstBeat) + f.features[i].map { String(format: "%4.0f", $0) }.joined())
                    }
                }
                print(String(format: "[phrase-debug]   beat %4d  bar %3d.%d  mod32 %2d  strength %.2f", n, n >= 0 ? n / 4 + 1 : n / 4, ((n % 4) + 4) % 4 + 1, ((n % 32) + 32) % 32, b.strength))
            }
        }
        let tag = r.suggests ? String(format: "%+d", r.shiftBeats) : "0"
        hist[tag, default: 0] += 1
        print(String(format: "[phrase] %+3d conf %.2f n %2d %@ anchor %7.0f ms bpm %.2f decode %.1fs ana %.2fs  %@ – %@",
                     r.shiftBeats, r.confidence, r.boundaries, r.suggests ? "*" : " ", t.gridAnchorMs ?? 0, t.bpm,
                     t1.timeIntervalSince(t0), dt, t.artist, t.title))
    }
    print("[phrase] verteilung: " + hist.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
}

/// Spektrum je Beat als Bild (13 Bänder, unten tief), Phrasenlinien: grau = jetziger Anker (oben), rot = Vorschlag (unten)
private func plot(_ f: [[Float]], firstBeat: Int, shift: Int, to url: URL) {
    let bw = 3, bands = f[0].count, bh = 12, h = bands * bh + 40, w = f.count * bw
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for k in 0..<bands {
        let col = f.map { $0[k] }
        let hi = col.max() ?? 0, lo = hi - 40
        for (i, v) in col.enumerated() {
            let x = CGFloat(max(0, min(1, (v - lo) / 40)))
            ctx.setFillColor(red: x, green: x, blue: x, alpha: 1)
            ctx.fill(CGRect(x: i * bw, y: 20 + k * bh, width: bw, height: bh))
        }
    }
    for i in f.indices {
        let n = i + firstBeat
        if ((n % 32) + 32) % 32 == 0 { ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1); ctx.fill(CGRect(x: i * bw, y: h - 20, width: 2, height: 20)) }
        if (((n - shift) % 32) + 32) % 32 == 0 { ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: i * bw, y: 0, width: 2, height: 20)) }
        if (((n - shift) % 4) + 4) % 4 == 0 { ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5); ctx.fill(CGRect(x: i * bw, y: 0, width: 1, height: 6)) }
    }
    guard let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

/// Vorschlag relativ zum jetzigen Anker: feine ms-Korrektur ändert ihn nicht, Übernehmen löscht ihn
@Test func phraseSuggestionFollowsAnchor() {
    var s = DeckState()
    s.grid = BeatGrid(anchor: 1, bpm: 120)   // Beat = 0.5 s
    #expect(s.phraseSuggestion == nil)
    s.phraseTarget = 1 - 3 * 0.5
    #expect(s.phraseSuggestion == -3)
    s.grid!.anchor += 0.004
    #expect(s.phraseSuggestion == -3)
    s.grid!.anchor -= 3 * 0.5
    #expect(s.phraseSuggestion == nil)
}
