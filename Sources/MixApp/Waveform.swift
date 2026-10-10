import CoreGraphics
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Vorberechnete Wellenform eines Tracks: Kacheln für die Scroll-Ansicht + ein Übersichtsbild.
final class RenderedWaveform: @unchecked Sendable {
    static let pxPerSec = 150.0
    static let tileWidth = 2048
    static let height = 160

    let tiles: [CGImage]
    let overview: CGImage?
    let duration: Double

    init(tiles: [CGImage], overview: CGImage?, duration: Double) {
        self.tiles = tiles
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
            case .traktor: Colors(low: RGB(r: 0.95, g: 0.25, b: 0.20), mid: RGB(r: 0.30, g: 0.85, b: 0.35), high: RGB(r: 0.30, g: 0.55, b: 1.0))
            }
        }
    }

    /// Spalte → (Spitze, Bass-, Mitten-, Höhenanteil)
    private static func column(_ a: TrackAudio, from: Int, to: Int) -> (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat) {
        let n = a.peak.count
        let s = max(0, min(n - 1, from)), e = max(s + 1, min(n, to))
        var pk: Float = 0, lo: Float = 0, mi: Float = 0, hi: Float = 0
        for i in s..<e {
            pk = max(pk, a.peak[i]); lo += a.low[i]; mi += a.mid[i]; hi += a.high[i]
        }
        let c = Float(e - s)
        return (CGFloat(pk), CGFloat(lo / c), CGFloat(mi / c), CGFloat(hi / c))
    }

    private static func draw(_ ctx: CGContext, x: CGFloat, h: CGFloat, col: (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat),
                             style: WaveformStyle, colors: Colors) {
        let mid = h / 2
        func bar(_ amp: CGFloat, _ c: RGB, alpha: CGFloat = 1) {
            let hh = max(0.5, amp * mid)
            ctx.setFillColor(CGColor(red: c.r, green: c.g, blue: c.b, alpha: alpha))
            ctx.fill(CGRect(x: x, y: mid - hh, width: 1, height: hh * 2))
        }
        switch style {
        case .threeBand:
            // Schichten: außen Bass, darin Mitten, innen Höhen (Amplitude je Band ~ √Anteil)
            bar(col.pk, colors.low)
            bar(col.pk * (col.mi + col.hi).squareRoot(), colors.mid)
            bar(col.pk * col.hi.squareRoot() * 0.9, colors.high)
        case .spectrum:
            let w = max(col.lo + col.mi + col.hi, 0.0001)
            let c = RGB(r: (colors.low.r * col.lo + colors.mid.r * col.mi + colors.high.r * col.hi) / w,
                        g: (colors.low.g * col.lo + colors.mid.g * col.mi + colors.high.g * col.hi) / w,
                        b: (colors.low.b * col.lo + colors.mid.b * col.mi + colors.high.b * col.hi) / w)
            bar(col.pk, c)
        case .mono:
            bar(col.pk, colors.mid)
        }
    }

    private static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func render(_ a: TrackAudio, style: WaveformStyle, palette: WaveformPalette) -> RenderedWaveform {
        let colors = Colors.of(palette)
        let bps = TrackAudio.blocksPerSecond
        let totalPx = Int(a.duration * pxPerSec) + 1
        var tiles: [CGImage] = []
        var x0 = 0
        while x0 < totalPx {
            let w = min(tileWidth, totalPx - x0)
            guard let ctx = context(width: w, height: height) else { break }
            for x in 0..<w {
                let t0 = Double(x0 + x) / pxPerSec, t1 = Double(x0 + x + 1) / pxPerSec
                // Fenster leicht überlappend → ruhigere Kontur
                let col = column(a, from: Int(t0 * bps) - 1, to: Int(t1 * bps) + 1)
                draw(ctx, x: CGFloat(x), h: CGFloat(height), col: col, style: style, colors: colors)
            }
            if let img = ctx.makeImage() { tiles.append(img) }
            x0 += w
        }
        // Übersicht
        let ow = 1600, oh = 60
        var overview: CGImage?
        if let ctx = context(width: ow, height: oh), !a.peak.isEmpty {
            let per = Double(a.peak.count) / Double(ow)
            for x in 0..<ow {
                let col = column(a, from: Int(Double(x) * per), to: Int(Double(x + 1) * per))
                draw(ctx, x: CGFloat(x), h: CGFloat(oh), col: col, style: style, colors: colors)
            }
            overview = ctx.makeImage()
        }
        return RenderedWaveform(tiles: tiles, overview: overview, duration: a.duration)
    }
}

/// Hält fertige Wellenformen je Track-Puffer und rechnet neue im Hintergrund.
@MainActor @Observable
final class WaveformCache {
    private var done: [String: RenderedWaveform] = [:]
    @ObservationIgnored private var running: Set<String> = []

    func waveform(for audio: TrackAudio?, style: WaveformStyle, palette: WaveformPalette) -> RenderedWaveform? {
        guard let audio else { return nil }
        let key = "\(ObjectIdentifier(audio).hashValue)-\(style.rawValue)-\(palette.rawValue)"
        if let w = done[key] { return w }
        if !running.contains(key) {
            running.insert(key)
            Task.detached(priority: .userInitiated) {
                let w = RenderedWaveform.render(audio, style: style, palette: palette)
                await MainActor.run {
                    self.done[key] = w
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

/// Scrollende Wellenform (Traktor-Stil): Ebenen auf der GPU, pro Frame nur verschoben.
struct WaveformView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int
    @State private var lastDrag: CGFloat?

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
        WaveLayerView(scene: scene, wave: wf, position: { [mix, d] in mix.position(d) }, loop: { [mix, d] in mix.engine.loop(d) })
            .overlay {
                if deck.track != nil, wf == nil {
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

/// Track-Übersicht: ganze Wellenform, gespielter Teil gedimmt, Cues, Loop; Klick springt.
struct OverviewView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), style: ui.waveformStyle, palette: ui.waveformPalette)
        GeometryReader { geo in
            LiveCanvas(fps: deck.playing ? 15 : 4, running: deck.duration > 0) { [mix, d] ctx, size in
                ctx.setFillColor(CG.wave); ctx.fill(CGRect(origin: .zero, size: size))
                guard deck.duration > 0 else { return }
                if let img = wf?.overview { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
                let f = mix.position(d) / deck.duration
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: size.width * f, height: size.height))
                let loop = mix.engine.loop(d)
                if loop.active {
                    ctx.setFillColor(NSColor(Theme.state).withAlphaComponent(0.4).cgColor)
                    ctx.fill(CGRect(x: loop.start / deck.duration * size.width, y: 0,
                                    width: max(2, (loop.end - loop.start) / deck.duration * size.width), height: size.height))
                }
                for c in deck.hotcues.values {
                    ctx.setFillColor(NSColor(Theme.cueColor(c, deck: deck, prefs: mix.prefs)).cgColor)
                    ctx.fill(CGRect(x: c.startMs / 1000 / deck.duration * size.width, y: 0, width: 2, height: size.height))
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
