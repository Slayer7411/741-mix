import CoreGraphics
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Vorberechnete Wellenform eines Tracks: Vektor-Abschnitte für die Scroll-Ansicht (GPU zeichnet sie in
/// Bildschirmauflösung, scharf bei jedem Zoom) + ein Übersichtsbild.
final class RenderedWaveform: @unchecked Sendable {
    /// Abschnitt: Pfade in Sekunden (x, ab `t0`) und Amplitude (y, -1…1 = 0 dBFS)
    struct Chunk { let t0: Double; let layers: [(color: CGColor, path: CGPath)] }
    static let chunkBlocks = 2048

    let chunks: [Chunk]
    let overview: CGImage?
    let duration: Double

    init(chunks: [Chunk], overview: CGImage?, duration: Double) {
        self.chunks = chunks
        self.overview = overview
        self.duration = duration
    }

    struct RGB { var r, g, b: CGFloat }

    struct Colors {
        var low: RGB, mid: RGB, high: RGB
        static func of(_ p: WaveformPalette) -> Colors {
            switch p {
            case .bone: Colors(low: RGB(r: 0.30, g: 0.27, b: 0.25), mid: RGB(r: 0.58, g: 0.54, b: 0.50), high: RGB(r: 0.90, g: 0.88, b: 0.85))
            case .orange: Colors(low: RGB(r: 0.78, g: 0.22, b: 0.06), mid: RGB(r: 1.0, g: 0.58, b: 0.14), high: RGB(r: 1.0, g: 0.92, b: 0.78))
            case .blue: Colors(low: RGB(r: 0.10, g: 0.32, b: 0.95), mid: RGB(r: 0.98, g: 0.62, b: 0.20), high: RGB(r: 1, g: 1, b: 1))
            case .classic: Colors(low: RGB(r: 1.0, g: 0.22, b: 0.10), mid: RGB(r: 0.25, g: 0.90, b: 0.40), high: RGB(r: 0.35, g: 0.45, b: 1.0))
            }
        }
    }

    /// Höhen-Ebene: Energieanteil flach abgebildet (Exponent 0,35 statt Wurzel), damit Hats auch unter Kick und Bass sichtbar bleiben
    static func highLevel(_ ratio: Float) -> CGFloat { CGFloat(pow(max(0, ratio), 0.35)) * 0.95 }

    /// Hüllkurve: Anschlag sofort, Abklingen ~20 ms (Kicks als klare Spitzen statt Rauschen)
    private static func envelope(_ a: TrackAudio) -> [Float] {
        var env = [Float](repeating: 0, count: a.peak.count)
        var e: Float = 0
        for i in env.indices { e = max(a.peak[i], e * 0.85); env[i] = e }
        return env
    }

    /// Spektrum-Farbe: Bänder additiv gemischt, auf volle Helligkeit gezogen
    private static func spectrum(_ lo: CGFloat, _ mi: CGFloat, _ hi: CGFloat, _ c: Colors) -> RGB {
        let r = c.low.r * lo + c.mid.r * mi + c.high.r * hi
        let g = c.low.g * lo + c.mid.g * mi + c.high.g * hi
        let b = c.low.b * lo + c.mid.b * mi + c.high.b * hi
        let m = max(r, g, b, 0.0001)
        return RGB(r: r / m, g: g / m, b: b / m)
    }

    /// Spalte → (Spitze, Bass-, Mitten-, Höhenanteil) über mehrere Blöcke (für die Übersicht)
    private static func column(_ a: TrackAudio, env: [Float], from: Int, to: Int) -> (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat) {
        let n = a.peak.count
        let s = max(0, min(n - 1, from)), e = max(s + 1, min(n, to))
        var pk: Float = 0, lo: Float = 0, mi: Float = 0, hi: Float = 0
        for i in s..<e {
            pk = max(pk, env[i]); lo += a.low[i]; mi += a.mid[i]; hi += a.high[i]
        }
        let c = Float(e - s)
        return (CGFloat(pk), CGFloat(lo / c), CGFloat(mi / c), CGFloat(hi / c))
    }

    private static func cg(_ c: RGB) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    /// Umriss oben + gespiegelt unten als ein Polygon
    private static func outline(_ amps: [CGFloat], dt: Double) -> CGPath {
        let p = CGMutablePath()
        guard !amps.isEmpty else { return p }
        p.move(to: CGPoint(x: 0, y: -amps[0]))
        for (i, v) in amps.enumerated() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: -v)) }
        p.addLine(to: CGPoint(x: Double(amps.count) * dt, y: -amps[amps.count - 1]))
        p.addLine(to: CGPoint(x: Double(amps.count) * dt, y: amps[amps.count - 1]))
        for (i, v) in amps.enumerated().reversed() { p.addLine(to: CGPoint(x: (Double(i) + 0.5) * dt, y: v)) }
        p.addLine(to: CGPoint(x: 0, y: amps[0]))
        p.closeSubpath()
        return p
    }

    private static func chunk(_ a: TrackAudio, env: [Float], range: Range<Int>, style: WaveformStyle, colors: Colors) -> [(CGColor, CGPath)] {
        let dt = 1 / TrackAudio.blocksPerSecond
        let pk = range.map { CGFloat(env[$0]) }
        switch style {
        case .mono:
            return [(cg(colors.mid), outline(pk, dt: dt))]
        case .threeBand:
            let mid = (0..<range.count).map { pk[$0] * CGFloat(a.mid[range.lowerBound + $0] + a.high[range.lowerBound + $0]).squareRoot() }
            let high = (0..<range.count).map { pk[$0] * Self.highLevel(a.high[range.lowerBound + $0]) }
            return [(cg(colors.low), outline(pk, dt: dt)), (cg(colors.mid), outline(mid, dt: dt)), (cg(colors.high), outline(high, dt: dt))]
        case .spectrum:
            // Farbe je Block auf 5 Stufen je Kanal gerundet → wenige Pfade, Blöcke als Rechtecke
            var paths: [Int: (RGB, CGMutablePath)] = [:]
            for k in 0..<range.count {
                let i = range.lowerBound + k
                var c = spectrum(CGFloat(a.low[i]), CGFloat(a.mid[i]), CGFloat(a.high[i]), colors)
                let q = { (v: CGFloat) in (v * 4).rounded() / 4 }
                c = RGB(r: q(c.r), g: q(c.g), b: q(c.b))
                let key = Int(c.r * 4) * 25 + Int(c.g * 4) * 5 + Int(c.b * 4)
                let path = paths[key]?.1 ?? CGMutablePath()
                if paths[key] == nil { paths[key] = (c, path) }
                let v = max(pk[k], 0.004)
                path.addRect(CGRect(x: Double(k) * dt, y: -v, width: dt * 1.02, height: v * 2))
            }
            return paths.values.map { (cg($0.0), $0.1) }
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawOverview(_ ctx: CGContext, x: CGFloat, h: CGFloat, col: (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat),
                                     style: WaveformStyle, colors: Colors) {
        let mid = h / 2
        func bar(_ amp: CGFloat, _ c: RGB) {
            let hh = max(0.5, amp * mid)
            ctx.setFillColor(cg(c))
            ctx.fill(CGRect(x: x, y: mid - hh, width: 1, height: hh * 2))
        }
        switch style {
        case .threeBand:
            bar(col.pk, colors.low)
            bar(col.pk * (col.mi + col.hi).squareRoot(), colors.mid)
            bar(col.pk * highLevel(Float(col.hi)), colors.high)
        case .spectrum:
            bar(col.pk, spectrum(col.lo, col.mi, col.hi, colors))
        case .mono:
            bar(col.pk, colors.mid)
        }
    }

    static func render(_ a: TrackAudio, style: WaveformStyle, palette: WaveformPalette) -> RenderedWaveform {
        let colors = Colors.of(palette)
        let env = envelope(a)
        let dt = 1 / TrackAudio.blocksPerSecond
        var chunks: [Chunk] = []
        var b0 = 0
        while b0 < env.count {
            let r = b0..<min(env.count, b0 + chunkBlocks)
            chunks.append(Chunk(t0: Double(b0) * dt, layers: chunk(a, env: env, range: r, style: style, colors: colors)))
            b0 = r.upperBound
        }
        // Übersicht
        let ow = 1600, oh = 60
        var overview: CGImage?
        if let ctx = context(width: ow, height: oh), !a.peak.isEmpty {
            let per = Double(a.peak.count) / Double(ow)
            for x in 0..<ow {
                let col = column(a, env: env, from: Int(Double(x) * per), to: Int(Double(x + 1) * per))
                drawOverview(ctx, x: CGFloat(x), h: CGFloat(oh), col: col, style: style, colors: colors)
            }
            overview = ctx.makeImage()
        }
        return RenderedWaveform(chunks: chunks, overview: overview, duration: a.duration)
    }
}

/// Hält fertige Wellenformen je Track-Puffer und rechnet neue im Hintergrund.
/// Schlüssel ist die Speicheradresse des Puffers – der Eintrag hält ihn schwach und gilt nur, solange genau dieser
/// Puffer lebt (ein neuer Track an derselben Adresse bekäme sonst die Wellenform des alten).
/// Wellenformen entladener Tracks fallen beim nächsten Eintrag weg.
@MainActor @Observable
final class WaveformCache {
    private struct Entry { weak var audio: TrackAudio?; let wave: RenderedWaveform }
    private var done: [String: Entry] = [:]
    @ObservationIgnored private var running: Set<String> = []

    func waveform(for audio: TrackAudio?, style: WaveformStyle, palette: WaveformPalette) -> RenderedWaveform? {
        guard let audio else { return nil }
        let key = "\(ObjectIdentifier(audio).hashValue)-\(style.rawValue)-\(palette.rawValue)"
        if let e = done[key], e.audio === audio { return e.wave }
        if !running.contains(key) {
            running.insert(key)
            Task.detached(priority: .userInitiated) {
                let w = RenderedWaveform.render(audio, style: style, palette: palette)
                await MainActor.run {
                    self.done.removeAll { $0.value.audio == nil }
                    self.done[key] = Entry(audio: audio, wave: w)
                    self.running.remove(key)
                    if self.done.count > 16 { self.done.removeAll { $0.key != key } }
                }
            }
        }
        return nil
    }
}

private extension Dictionary {
    mutating func removeAll(where f: (Element) -> Bool) {
        for (k, v) in self where f((k, v)) { self[k] = nil }
    }
}

/// Scrollende Wellenform: Ebenen auf der GPU, pro Frame nur verschoben.
/// Hülle liest Deck und Einstellungen, die Equatable-Ansicht darunter rendert nur bei geänderter Szene neu.
struct WaveformView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), style: ui.waveformStyle, palette: ui.waveformPalette)
        let scene = WaveScene(
            waveID: wf.map { ObjectIdentifier($0) }, duration: deck.duration, grid: deck.grid, span: ui.waveformSeconds,
            showGrid: ui.showBeatgrid, colorful: ui.colorfulGrid, phraseBeats: ui.phraseBeats, barNumbers: ui.showBarNumbers, barMarkers: ui.barMarkers,
            dimPlayed: ui.dimPlayed,
            cues: deck.hotcues.values.sorted { $0.hotcue < $1.hotcue }.map {
                WaveScene.Mark(t: $0.startMs / 1000, number: $0.hotcue + 1, color: NSColor(Theme.cueColor($0, deck: deck, prefs: mix.prefs)))
            },
            cuePoint: deck.cuePoint, hasTrack: deck.track != nil)
        Content(d: d, scene: scene, wave: wf, waiting: deck.track != nil && wf == nil).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let scene: WaveScene
        let wave: RenderedWaveform?
        let waiting: Bool
        @State private var lastDrag: CGFloat?
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.scene == b.scene && a.wave === b.wave && a.waiting == b.waiting }

        var body: some View {
            WaveLayerView(scene: scene, wave: wave, position: { [mix, d] in mix.position(d) }, loop: { [mix, d] in mix.engine.loop(d) })
                .overlay {
                    if waiting {
                        Text("Wellenform wird berechnet …").font(Theme.mono(10)).foregroundStyle(.secondary)
                    }
                }
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    let dx = g.translation.width - (lastDrag ?? 0)
                                    lastDrag = g.translation.width
                                    let secPerPt = mix.prefs.ui.waveformSeconds * 2 / geo.size.width
                                    mix.core.seek(d, seconds: mix.position(d) - Double(dx) * secPerPt)
                                }
                                .onEnded { _ in lastDrag = nil })
                    }
                }
        }
    }
}

/// Track-Übersicht: ganze Wellenform, gespielter Teil gedimmt, Cues, Loop; Klick springt.
struct OverviewView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    struct Model: Equatable {
        var duration = 0.0, playing = false
        var cues: [WaveScene.Mark] = []
    }

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), style: ui.waveformStyle, palette: ui.waveformPalette)
        let cues = deck.hotcues.values.map {
            WaveScene.Mark(t: $0.startMs / 1000, number: $0.hotcue + 1, color: NSColor(Theme.cueColor($0, deck: deck, prefs: mix.prefs)))
        }
        Content(d: d, m: Model(duration: deck.duration, playing: deck.playing, cues: cues), wave: wf).equatable()
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        let d: Int
        let m: Model
        let wave: RenderedWaveform?
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m && a.wave === b.wave }

        var body: some View {
            let m = m, wf = wave
            GeometryReader { geo in
                LiveCanvas(fps: m.playing ? 15 : 4, running: m.duration > 0) { [mix, d] ctx, size in
                    ctx.setFillColor(CG.wave); ctx.fill(CGRect(origin: .zero, size: size))
                    guard m.duration > 0 else { return }
                    if let img = wf?.overview { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
                    let f = mix.position(d) / m.duration
                    ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: size.width * f, height: size.height))
                    let loop = mix.engine.loop(d)
                    if loop.active {
                        ctx.setFillColor(NSColor(Theme.state).withAlphaComponent(0.4).cgColor)
                        ctx.fill(CGRect(x: loop.start / m.duration * size.width, y: 0,
                                        width: max(2, (loop.end - loop.start) / m.duration * size.width), height: size.height))
                    }
                    for c in m.cues {
                        ctx.setFillColor(c.color.cgColor)
                        ctx.fill(CGRect(x: c.t / m.duration * size.width, y: 0, width: 2, height: size.height))
                    }
                    ctx.setFillColor(CG.state)
                    ctx.fill(CGRect(x: size.width * f - 1, y: 0, width: 2, height: size.height))
                }
                .clipShape(Rectangle())
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    mix.seek(d, fraction: v.location.x / geo.size.width)
                })
            }
        }
    }
}
