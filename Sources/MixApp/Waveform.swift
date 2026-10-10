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
        // leichte Kompression, damit leise Stellen sichtbar bleiben
        return (CGFloat(pow(pk, 0.8)), CGFloat(lo / c), CGFloat(mi / c), CGFloat(hi / c))
    }

    private static func draw(_ ctx: CGContext, x: CGFloat, h: CGFloat, col: (pk: CGFloat, lo: CGFloat, mi: CGFloat, hi: CGFloat),
                             style: WaveformStyle, colors: Colors) {
        let mid = h / 2
        func bar(_ amp: CGFloat, _ c: RGB, alpha: CGFloat = 1) {
            let hh = max(0.5, amp * mid * 0.96)
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

/// Scrollende Wellenform (Traktor-Stil): Kacheln, gedimmter gespielter Teil, Beatgrid mit Taktmarken, Cues, Loop.
struct WaveformView: View {
    @Environment(MixModel.self) private var mix
    @Environment(WaveformCache.self) private var cache
    let d: Int
    @State private var lastDrag: CGFloat?

    var body: some View {
        let ui = mix.prefs.ui
        let deck = mix.deck(d)
        let wf = cache.waveform(for: mix.audio(d), style: ui.waveformStyle, palette: ui.waveformPalette)
        let tileImages = wf?.tiles.map { Image(decorative: $0, scale: 1) } ?? []
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: deck.track == nil)) { _ in
            Canvas(rendersAsynchronously: true) { ctx, size in
                let w = size.width, h = size.height
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.wave))
                guard deck.track != nil else { return }
                let span = ui.waveformSeconds
                let pos = mix.position(d)
                let secPerPt = span * 2 / w
                func x(_ t: Double) -> CGFloat { (t - pos) / secPerPt + w / 2 }

                // Wellenform-Kacheln
                if let wf {
                    let tileSec = Double(RenderedWaveform.tileWidth) / RenderedWaveform.pxPerSec
                    for (i, img) in tileImages.enumerated() {
                        let t0 = Double(i) * tileSec
                        let tw = Double(wf.tiles[i].width) / RenderedWaveform.pxPerSec
                        guard t0 + tw > pos - span, t0 < pos + span else { continue }
                        ctx.draw(img, in: CGRect(x: x(t0), y: 0, width: tw / secPerPt, height: h))
                    }
                } else {
                    ctx.draw(Text("Wellenform wird berechnet …").font(Theme.mono(10)).foregroundStyle(.secondary),
                             at: CGPoint(x: w / 2, y: h / 2))
                }
                // gespielter Teil gedimmt
                if ui.dimPlayed {
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: w / 2, height: h)), with: .color(.black.opacity(0.32)))
                }
                // Loop
                let loop = mix.engine.loop(d)
                if loop.active {
                    let r = CGRect(x: x(loop.start), y: 0, width: x(loop.end) - x(loop.start), height: h)
                    ctx.fill(Path(r), with: .color(Theme.state.opacity(0.14)))
                    ctx.fill(Path(CGRect(x: r.minX, y: 0, width: 1, height: h)), with: .color(Theme.state))
                    ctx.fill(Path(CGRect(x: r.maxX - 1, y: 0, width: 1, height: h)), with: .color(Theme.state))
                }
                // Beatgrid: Phrasen-Bänder (lila), Taktlinien mit Marken, Beat-Ticks, Phrasen-Countdown
                if ui.showBeatgrid, let g = deck.grid {
                    let first = g.beatPosition(at: pos - span).rounded(.up)
                    let last = g.beatPosition(at: pos + span).rounded(.down)
                    let phrase = Double(max(4, ui.phraseBeats))
                    if ui.colorfulGrid {
                        // jede zweite Phrase leicht eingefärbt
                        var p = (first / phrase).rounded(.down) * phrase
                        while p <= last {
                            if Int(p / phrase) % 2 == 1 {
                                let x0 = x(g.time(ofBeat: p)), x1 = x(g.time(ofBeat: p + phrase))
                                ctx.fill(Path(CGRect(x: x0, y: 0, width: x1 - x0, height: h)), with: .color(Theme.secondary.opacity(0.10)))
                            }
                            p += phrase
                        }
                    }
                    if last - first < 600 {
                        for b in stride(from: first, through: last, by: 1) {
                            let bx = x(g.time(ofBeat: b))
                            let ib = Int(b)
                            let isBar = ib % 4 == 0
                            let isPhrase = ib % Int(phrase) == 0
                            if isPhrase && ui.colorfulGrid {
                                ctx.fill(Path(CGRect(x: bx - 1, y: 0, width: 2, height: h)), with: .color(Theme.secondary))
                                ctx.draw(Text("P\(ib / Int(phrase) + 1)").font(Theme.mono(9, .semibold)).foregroundStyle(Theme.secondary),
                                         at: CGPoint(x: bx + 3, y: h - 9), anchor: .leading)
                            } else {
                                ctx.fill(Path(CGRect(x: bx - 0.5, y: 0, width: 1, height: h)),
                                         with: .color(Theme.bone.opacity(isBar ? 0.32 : 0.09)))
                            }
                            // Beat-Ticks oben/unten: Taktanfang groß, übrige Beats klein
                            let tick: CGFloat = isBar ? 6 : 3
                            let tc = isBar ? Theme.bone : Theme.muted
                            ctx.fill(Path(CGRect(x: bx - 1, y: 0, width: 2, height: tick)), with: .color(tc))
                            ctx.fill(Path(CGRect(x: bx - 1, y: h - tick, width: 2, height: tick)), with: .color(tc))
                            if ui.showBarNumbers, isBar, ib % 16 == 0, !(isPhrase && ui.colorfulGrid) {
                                ctx.draw(Text("\(ib / 4 + 1)").font(Theme.mono(8, .semibold)).foregroundStyle(Theme.bone.opacity(0.7)),
                                         at: CGPoint(x: bx + 3, y: 10), anchor: .leading)
                            }
                        }
                    }
                    // Countdown bis zur nächsten Phrase (in Takten)
                    if ui.colorfulGrid {
                        let bp = g.beatPosition(at: pos)
                        let toNext = phrase - (bp - (bp / phrase).rounded(.down) * phrase)
                        let bars = Int((toNext / 4).rounded(.up))
                        let label = "P\(Int((bp / phrase).rounded(.down)) + 1) · \(bars) T"
                        ctx.draw(Text(label).font(Theme.mono(10, .semibold)).foregroundStyle(bars <= 1 ? Theme.state : Theme.bone),
                                 at: CGPoint(x: w / 2 + 6, y: 9), anchor: .leading)
                    }
                }
                // Hotcues als Fahnen
                for c in deck.hotcues.values {
                    let cx = x(c.startMs / 1000)
                    guard cx > -20, cx < w + 20 else { continue }
                    let col = Theme.cueColor(c, deck: deck, prefs: mix.prefs)
                    ctx.fill(Path(CGRect(x: cx - 1, y: 0, width: 2, height: h)), with: .color(col))
                    ctx.fill(Path(roundedRect: CGRect(x: cx, y: 0, width: 13, height: 12), cornerRadius: 2), with: .color(col))
                    ctx.draw(Text("\(c.hotcue + 1)").font(Theme.label(9, .heavy)).foregroundStyle(.black),
                             at: CGPoint(x: cx + 6.5, y: 6))
                }
                // Cue-Punkt
                let cueX = x(deck.cuePoint)
                var cueTri = Path()
                cueTri.move(to: CGPoint(x: cueX - 5, y: h)); cueTri.addLine(to: CGPoint(x: cueX + 5, y: h))
                cueTri.addLine(to: CGPoint(x: cueX, y: h - 8)); cueTri.closeSubpath()
                ctx.fill(cueTri, with: .color(Theme.bone))
                // Abspielkopf
                ctx.fill(Path(CGRect(x: w / 2 - 2, y: 0, width: 4, height: h)), with: .color(.black.opacity(0.5)))
                ctx.fill(Path(CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)), with: .color(Theme.state))
            }
        }
        .drawingGroup()
        .clipShape(Rectangle())
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
        let img = wf?.overview.map { Image(decorative: $0, scale: 1) }
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 15, paused: deck.track == nil)) { _ in
                Canvas(rendersAsynchronously: true) { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.wave))
                    guard deck.duration > 0 else { return }
                    if let img { ctx.draw(img, in: CGRect(origin: .zero, size: size)) }
                    let f = mix.position(d) / deck.duration
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * f, height: size.height)), with: .color(.black.opacity(0.45)))
                    let loop = mix.engine.loop(d)
                    if loop.active {
                        ctx.fill(Path(CGRect(x: loop.start / deck.duration * size.width, y: 0,
                                             width: max(2, (loop.end - loop.start) / deck.duration * size.width), height: size.height)),
                                 with: .color(Theme.state.opacity(0.4)))
                    }
                    for c in deck.hotcues.values {
                        ctx.fill(Path(CGRect(x: c.startMs / 1000 / deck.duration * size.width, y: 0, width: 2, height: size.height)),
                                 with: .color(Theme.cueColor(c, deck: deck, prefs: mix.prefs)))
                    }
                    ctx.fill(Path(CGRect(x: size.width * f - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.state))
                }
            }
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                mix.seek(d, fraction: v.location.x / geo.size.width)
            })
        }
    }
}
