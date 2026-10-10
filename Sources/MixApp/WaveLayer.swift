import AppKit
import QuartzCore
import SwiftUI
import MixCore
import MixEngine

/// Was die Wellenform zeigt – ändert sich selten. Pro Frame wird nur verschoben (Textur auf der GPU, Shader-Offset).
struct WaveScene: Equatable {
    struct Mark: Equatable {
        var t: Double, number: Int, rgba: [CGFloat]
        init(t: Double, number: Int, color: NSColor) {
            self.t = t; self.number = number
            let c = color.usingColorSpace(.sRGB) ?? color
            rgba = [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
        }
        var color: NSColor { NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) }
    }
    var waveID: ObjectIdentifier?
    var duration: Double = 0
    var grid: BeatGrid?
    var span = 4.0
    var showGrid = true
    var colorful = true
    var phraseBeats = 64
    var barNumbers = true
    var barMarkers = true
    var dimPlayed = true
    var cues: [Mark] = []
    var cuePoint: Double = 0
    var hasTrack = false

    /// ändert sich das, müssen die Wellenform-Kacheln neu gerechnet werden
    var tileKey: String { "\(waveID.map { "\($0)" } ?? "-")|\(duration)|\(span)|\(hasTrack)" }
}

struct WaveLayerView: NSViewRepresentable {
    let scene: WaveScene
    let wave: RenderedWaveform?
    let position: @MainActor () -> Double
    let loop: @MainActor () -> (active: Bool, start: Double, end: Double)

    func makeNSView(context: Context) -> WaveLayerNSView { WaveLayerNSView() }

    func updateNSView(_ v: WaveLayerNSView, context: Context) {
        v.position = position
        v.loop = loop
        v.wave = wave
        v.scene = scene
    }
}

/// Wellenform-Ansicht ohne SwiftUI im Frame-Takt. Drei Ebenen im scrollenden Streifen:
/// Kacheln (Bitmaps der Wellenform, im Hintergrund gerendert, nur rund um den Spielkopf), Beatgrid, Cues.
/// Vektor-Pfade pro Frame zu zeichnen hat den Render-Server ausgelastet (Hauptthread wartete in CA synchronize).
final class WaveLayerNSView: NSView {
    var position: @MainActor () -> Double = { 0 }
    var loop: @MainActor () -> (active: Bool, start: Double, end: Double) = { (false, 0, 0) }
    var wave: RenderedWaveform? { didSet { if wave !== oldValue { rebuild(tiles: true) } } }
    var scene = WaveScene() {
        didSet { if scene != oldValue { rebuild(tiles: scene.tileKey != oldValue.tileKey) } }
    }

    private let content = CALayer()   // gespiegelt: y nach unten
    private let strip = CALayer()
    private let tiles = CALayer(), gridLayer = CALayer(), cueLayer = CALayer()
    private let loopLayer = CALayer()
    private let dim = CALayer()
    private let playhead = CALayer()
    private let countdown = CATextLayer()
    private var link: CADisplayLink?
    private var builtSize: CGSize = .zero
    private var pps: Double = 1   // Punkte pro Sekunde bei aktuellem Zoom
    private var lastLoop: (Bool, Double, Double) = (false, 0, 0)
    private var lastCountdown = ""
    private var lastPos = Double.nan

    // Kacheln
    private static let tileQueue = DispatchQueue(label: "minos741.wavetiles", qos: .userInitiated)
    private static let tileWidth: CGFloat = 1024   // Punkte
    private var tileLayers: [Int: CALayer] = [:]
    private var tilesPending: Set<Int> = []
    private var tileGen = 0

    private static let ruler: CGFloat = 14
    private static let monoBold = CTFontCreateWithName("IBMPlexMono-SemiBold" as CFString, 9, nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        content.isGeometryFlipped = true
        content.anchorPoint = .zero
        content.actions = Self.noAnimation
        layer?.addSublayer(content)
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(Theme.wave).cgColor
        strip.anchorPoint = .zero
        loopLayer.backgroundColor = NSColor(Theme.state).withAlphaComponent(0.14).cgColor
        loopLayer.borderColor = NSColor(Theme.state).cgColor
        loopLayer.borderWidth = 1
        loopLayer.isHidden = true
        dim.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        playhead.backgroundColor = NSColor(Theme.state).cgColor
        playhead.shadowColor = NSColor.black.cgColor
        playhead.shadowOpacity = 0.6
        playhead.shadowRadius = 1
        playhead.shadowOffset = .zero
        countdown.font = Self.monoBold
        countdown.fontSize = 10
        countdown.contentsScale = 2
        for l in [tiles, gridLayer, loopLayer, cueLayer] { strip.addSublayer(l) }
        for l in [strip, dim, playhead, countdown] { content.addSublayer(l) }
        for l in [strip, tiles, gridLayer, cueLayer, loopLayer, dim, playhead, countdown] as [CALayer] { l.actions = Self.noAnimation }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static let noAnimation: [String: CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(), "contents": NSNull(), "string": NSNull(),
        "foregroundColor": NSNull(), "sublayers": NSNull(),
    ]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func layout() {
        super.layout()
        if bounds.size != builtSize { rebuild(tiles: true) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild(tiles: true)
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    // MARK: Aufbau (nur bei Änderungen)

    /// Grid und Cues neu; die Kacheln nur, wenn sich Wellenform, Zoom oder Größe geändert haben
    private func rebuild(tiles rebuildTiles: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let w = bounds.width, h = bounds.height
        builtSize = bounds.size
        content.frame = bounds
        dim.frame = CGRect(x: 0, y: 0, width: w / 2, height: h)
        dim.isHidden = !scene.dimPlayed || !scene.hasTrack
        playhead.frame = CGRect(x: (w / 2 - 1).rounded(), y: 0, width: 2, height: h)
        playhead.isHidden = !scene.hasTrack
        countdown.isHidden = true
        strip.isHidden = !scene.hasTrack
        guard scene.hasTrack, w > 0, h > 0 else { clearTiles(); return }
        pps = Double(w) / (scene.span * 2)
        let total = CGFloat(scene.duration * pps)
        strip.frame = CGRect(x: 0, y: 0, width: total, height: h)
        if rebuildTiles { clearTiles() }
        tiles.frame = strip.bounds
        gridLayer.sublayers = nil
        gridLayer.frame = strip.bounds
        cueLayer.sublayers = nil
        cueLayer.frame = strip.bounds
        lastLoop = (false, -1, -1)
        lastPos = .nan
        if scene.showGrid, let g = scene.grid, g.bpm > 0 { buildGrid(g, h: h) }
        buildCues(h: h)
        step()
    }

    private func clearTiles() {
        tileGen += 1
        tileLayers.values.forEach { $0.removeFromSuperlayer() }
        tileLayers = [:]
        tilesPending = []
    }

    private func px(_ v: Double) -> CGFloat { (CGFloat(v) * scale).rounded() / scale }

    private func shape(_ path: CGPath, _ color: NSColor) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.actions = Self.noAnimation
        s.path = path
        s.fillColor = color.cgColor
        return s
    }

    private func text(_ str: String, _ color: NSColor, at p: CGPoint, size: CGFloat = 9) -> CATextLayer {
        let t = CATextLayer()
        t.actions = Self.noAnimation
        t.string = str
        t.font = Self.monoBold
        t.fontSize = size
        t.foregroundColor = color.cgColor
        t.contentsScale = scale
        t.frame = CGRect(x: p.x, y: p.y, width: CGFloat(str.count) * size * 0.62 + 4, height: size + 3)
        return t
    }

    private func buildGrid(_ g: BeatGrid, h: CGFloat) {
        let r = Self.ruler
        let bone = NSColor(Theme.bone), lila = NSColor(Theme.secondary), muted = NSColor(Theme.muted)
        let phrase = max(4, scene.phraseBeats)
        let first = Int(g.beatPosition(at: 0).rounded(.up))
        let last = Int(g.beatPosition(at: scene.duration).rounded(.down))
        guard last > first, last - first < 5000 else { return }
        let bands = CGMutablePath(), beats = CGMutablePath(), bars = CGMutablePath(), phrases = CGMutablePath()
        let tris = CGMutablePath(), ptris = CGMutablePath(), ticks = CGMutablePath()
        let caps = CGMutablePath(), barCaps = CGMutablePath()
        let hair = 1 / scale   // ein Gerätepixel
        let m8 = CGMutablePath(), m16 = CGMutablePath(), m32 = CGMutablePath()
        let magenta = NSColor(srgbRed: 0.88, green: 0.22, blue: 0.78, alpha: 1)
        let labels = CALayer()
        labels.actions = Self.noAnimation
        for b in first...last {
            let x = px(g.time(ofBeat: Double(b)) * pps)
            let inBar = ((b % 4) + 4) % 4
            let isPhrase = scene.colorful && ((b % phrase) + phrase) % phrase == 0
            if isPhrase, (((b / phrase) % 2) + 2) % 2 == 1 {
                let x1 = px(g.time(ofBeat: Double(b + phrase)) * pps)
                bands.addRect(CGRect(x: x, y: 0, width: x1 - x, height: h))
            }
            let barIdx = b / 4
            let mark = scene.barMarkers && inBar == 0 ? (barIdx % 32 == 0 ? 32 : barIdx % 16 == 0 ? 16 : barIdx % 8 == 0 ? 8 : 0) : 0
            if mark > 0 {
                let mw: CGFloat = mark == 32 ? 4 : mark == 16 ? 3 : 2
                (mark == 32 ? m32 : mark == 16 ? m16 : m8).addRect(CGRect(x: x - mw / 2, y: r, width: mw, height: h - r))
            } else if isPhrase {
                phrases.addRect(CGRect(x: x - 1, y: r, width: 2, height: h - r))
            } else if inBar == 0 {
                bars.addRect(CGRect(x: x - hair, y: r, width: hair * 2, height: h - r))
            } else {
                beats.addRect(CGRect(x: x - hair / 2, y: r, width: hair, height: h - r))
            }
            if inBar == 0 {
                let tp = isPhrase ? ptris : tris
                tp.move(to: CGPoint(x: x - 5, y: r)); tp.addLine(to: CGPoint(x: x + 5, y: r))
                tp.addLine(to: CGPoint(x: x, y: r + 6)); tp.closeSubpath()
                let perPhrase = phrase / 4
                let barInPhrase = (((b / 4) % perPhrase) + perPhrase) % perPhrase + 1
                let label = mark > 0 ? "\(mark)" : isPhrase ? "P\(b / phrase + 1)" : (scene.barNumbers ? "\(barInPhrase)" : "")
                if !label.isEmpty {
                    labels.addSublayer(text(label, mark > 0 ? magenta : isPhrase ? lila : bone.withAlphaComponent(0.85), at: CGPoint(x: x + 3, y: 1)))
                }
            } else {
                ticks.addRect(CGRect(x: x - 0.5, y: r - 4, width: 1, height: 4))
            }
            // Kappen oben und unten (Takt breiter)
            let cw: CGFloat = inBar == 0 ? 7 : 5
            let cap = inBar == 0 ? barCaps : caps
            cap.addRect(CGRect(x: x - cw / 2, y: r, width: cw, height: 1.5))
            cap.addRect(CGRect(x: x - cw / 2, y: h - 1.5, width: cw, height: 1.5))
        }
        let rulerBG = CALayer()
        rulerBG.actions = Self.noAnimation
        rulerBG.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        rulerBG.frame = CGRect(x: 0, y: 0, width: strip.bounds.width, height: r)
        gridLayer.addSublayer(shape(bands, lila.withAlphaComponent(0.08)))
        gridLayer.addSublayer(rulerBG)
        gridLayer.addSublayer(shape(beats, bone.withAlphaComponent(0.55)))
        gridLayer.addSublayer(shape(bars, bone))
        gridLayer.addSublayer(shape(caps, bone.withAlphaComponent(0.7)))
        gridLayer.addSublayer(shape(barCaps, bone))
        gridLayer.addSublayer(shape(phrases, lila))
        gridLayer.addSublayer(shape(m8, magenta.withAlphaComponent(0.7)))
        gridLayer.addSublayer(shape(m16, magenta.withAlphaComponent(0.9)))
        gridLayer.addSublayer(shape(m32, magenta))
        gridLayer.addSublayer(shape(ticks, muted))
        gridLayer.addSublayer(shape(tris, bone))
        gridLayer.addSublayer(shape(ptris, lila))
        gridLayer.addSublayer(labels)
        // Grid-Anker
        let ax = px(g.anchor * pps)
        let anchor = CGMutablePath()
        anchor.addRect(CGRect(x: ax - 1, y: 0, width: 2, height: h))
        anchor.addRect(CGRect(x: ax, y: r, width: 10, height: 10))
        gridLayer.addSublayer(shape(anchor, bone))
        gridLayer.addSublayer(text("G", .black, at: CGPoint(x: ax + 1.5, y: r - 1), size: 8))
        countdown.isHidden = !scene.colorful
    }

    private func buildCues(h: CGFloat) {
        for c in scene.cues {
            let x = px(c.t * pps)
            let p = CGMutablePath()
            p.addRect(CGRect(x: x - 1, y: 0, width: 2, height: h))
            p.addRect(CGRect(x: x, y: h - 26, width: 13, height: 12))
            cueLayer.addSublayer(shape(p, c.color))
            cueLayer.addSublayer(text("\(c.number)", .black, at: CGPoint(x: x + 3, y: h - 27), size: 9))
        }
        let cx = px(scene.cuePoint * pps)
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: cx - 5, y: h)); tri.addLine(to: CGPoint(x: cx + 5, y: h))
        tri.addLine(to: CGPoint(x: cx, y: h - 8)); tri.closeSubpath()
        cueLayer.addSublayer(shape(tri, NSColor(Theme.bone)))
    }

    // MARK: Kacheln (Bitmaps rund um den Spielkopf, im Hintergrund gerendert)

    private func updateTiles(_ pos: Double) {
        guard let wave, scene.hasTrack else { return }
        let tw = Self.tileWidth, w = bounds.width, h = bounds.height
        let total = CGFloat(scene.duration * pps)
        guard total > 0, h > 0 else { return }
        let x0 = max(0, CGFloat(pos * pps) - w / 2), x1 = min(total, x0 + w)
        let maxIndex = max(0, Int((total / tw).rounded(.up)) - 1)
        let first = max(0, Int(x0 / tw) - 1), last = min(maxIndex, Int(x1 / tw) + 1)
        guard first <= last else { return }
        for (i, l) in tileLayers where i < first - 2 || i > last + 2 {
            l.removeFromSuperlayer()
            tileLayers[i] = nil
        }
        for i in first...last where tileLayers[i] == nil && !tilesPending.contains(i) {
            tilesPending.insert(i)
            let gen = tileGen, pps = pps, scale = scale, chunks = wave.chunks
            Self.tileQueue.async {
                let img = Self.renderTile(i, chunks: chunks, pps: pps, h: h, tw: tw, scale: scale)
                DispatchQueue.main.async { [weak self] in
                    guard let self, gen == self.tileGen else { return }
                    self.tilesPending.remove(i)
                    guard let img else { return }
                    let l = CALayer()
                    l.actions = Self.noAnimation
                    l.contents = img
                    l.contentsScale = scale
                    l.contentsGravity = .resize
                    l.frame = CGRect(x: CGFloat(i) * tw, y: 0, width: tw, height: h)
                    self.tiles.addSublayer(l)
                    self.tileLayers[i] = l
                }
            }
        }
    }

    /// eine Kachel in Bildschirmauflösung zeichnen (Hintergrund-Queue; Pfade und Farben sind unveränderliche CF-Objekte)
    private static func renderTile(_ i: Int, chunks: [RenderedWaveform.Chunk], pps: Double, h: CGFloat, tw: CGFloat, scale: CGFloat) -> CGImage? {
        let pw = Int(tw * scale), ph = Int(h * scale)
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let x0 = CGFloat(i) * tw
        let t0 = Double(x0) / pps, t1 = Double(x0 + tw) / pps
        let chunkSeconds = Double(RenderedWaveform.chunkBlocks) / TrackAudio.blocksPerSecond
        // Pfade sind um 0 gespiegelt → Ausrichtung der y-Achse spielt keine Rolle
        for c in chunks where c.t0 + chunkSeconds >= t0 && c.t0 <= t1 {
            var t = CGAffineTransform(a: CGFloat(pps), b: 0, c: 0, d: h / 2, tx: CGFloat(c.t0 * pps) - x0, ty: h / 2)
            for l in c.layers {
                guard let p = l.path.copy(using: &t) else { continue }
                ctx.setFillColor(l.color)
                ctx.addPath(p)
                ctx.fillPath()
            }
        }
        return ctx.makeImage()
    }

    // MARK: pro Frame: nur verschieben

    @objc private func step() {
        guard scene.hasTrack else { return }
        let pos = position()
        let l = loop()
        let loopChanged = l.active != lastLoop.0 || l.start != lastLoop.1 || l.end != lastLoop.2
        // Deck steht: nichts verschieben, keine Transaktion (sonst 4 Decks × 120 Hz im Leerlauf)
        if pos == lastPos, !loopChanged, tilesPending.isEmpty { return }
        lastPos = pos
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let x = Double(bounds.width / 2) - pos * pps
        strip.position = CGPoint(x: (CGFloat(x) * scale).rounded() / scale, y: 0)
        updateTiles(pos)
        if loopChanged {
            lastLoop = (l.active, l.start, l.end)
            loopLayer.isHidden = !l.active
            if l.active {
                loopLayer.frame = CGRect(x: CGFloat(l.start * pps), y: 0, width: CGFloat((l.end - l.start) * pps), height: bounds.height)
            }
        }
        if !countdown.isHidden, let g = scene.grid {
            let phrase = Double(max(4, scene.phraseBeats))
            let bp = g.beatPosition(at: pos)
            let toNext = phrase - (bp - (bp / phrase).rounded(.down) * phrase)
            let bars = Int((toNext / 4).rounded(.up))
            let s = "P\(Int((bp / phrase).rounded(.down)) + 1) · \(bars) T"
            if s != lastCountdown {
                lastCountdown = s
                countdown.string = s
                countdown.foregroundColor = NSColor(bars <= 1 ? Theme.state : Theme.bone).cgColor
                countdown.frame = CGRect(x: bounds.width / 2 + 6, y: Self.ruler + 3, width: 120, height: 14)
            }
        }
        CATransaction.commit()
    }
}
