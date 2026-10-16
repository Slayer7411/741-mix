import AppKit
import SwiftUI
import MixCore
import MixMedia
import MixEngine

/// Was die Wellenform neu zeichnen lässt (Werte selbst liest sie aus dem Modus)
struct AudioEditWaveState: Equatable {
    var selection: TrackRange?
    var cursor: Double
    var secPerPoint: Double
    var viewStart: Double
    var marks: [AudioMarker]
    var edit: WaveScene.EditMarks?
    var duration: Double
    var revision: Int
}

/// Wellenform des Editors (Deck A, Ausgabe der Schnittliste) als AppKit-Fläche: Zoom bis auf die Samples, Auswahl, Cursor,
/// Spielkopf, Marken, Nähte, Lupe beim Ziehen einer Auswahlkante
struct AudioEditWave: NSViewRepresentable {
    let state: AudioEditWaveState

    func makeNSView(context: Context) -> AudioEditCanvas { AudioEditCanvas() }

    func updateNSView(_ v: AudioEditCanvas, context: Context) {
        v.stamp = state
    }
}

/// Zeichnen und Maus der Wellenform. Befehle gehen an `AudioEditMode` (AudioEditor.swift)
@MainActor
final class AudioEditCanvas: NSView {
    /// Vergleichswert: ändert sich er oder die Ansicht, wird neu gezeichnet
    var stamp = AudioEditWaveState(selection: nil, cursor: 0, secPerPoint: 0, viewStart: 0, marks: [], edit: nil, duration: 0, revision: 0) {
        didSet { if stamp != oldValue { needsDisplay = true } }
    }
    private let rulerH: CGFloat = 20
    private let stripH: CGFloat = 12
    private var timer: Timer?
    private var lastPlayX: CGFloat = -1

    private enum Drag: Equatable { case select, edge }
    private var drag: Drag?
    private var dragAnchor = 0.0
    private var dragMoved = false
    private var dragShift = false
    /// Lupe beim Ziehen einer Auswahlkante: Zeit und x des Punkts
    private var loupe: (t: Double, x: CGFloat)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var waveRect: NSRect { NSRect(x: 0, y: rulerH, width: bounds.width, height: max(0, bounds.height - rulerH - stripH)) }

    /// Spielkopf nachführen und nur neu zeichnen, wenn er sich auf dem Bildschirm bewegt
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(timeInterval: 1.0 / 30, target: self, selector: #selector(tickTimer), userInfo: nil, repeats: true)
    }

    @objc private func tickTimer() { tick() }

    private func tick() {
        let m = AudioEditMode.shared
        guard m.audio != nil, m.secPerPoint > 0 else { return }
        m.followPlayhead()
        let x = CGFloat(m.x(atTime: m.playhead))
        if abs(x - lastPlayX) >= 0.5 {
            lastPlayX = x
            needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        AudioEditMode.shared.layoutChanged(width: Double(bounds.width))
        needsDisplay = true
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Theme.chitin).setFill()
        bounds.fill()
        let m = AudioEditMode.shared
        guard let a = m.audio, a.frames > 0, m.secPerPoint > 0, bounds.width > 0 else {
            drawCentered(m.current == nil ? String(localized: "kein Track geladen") : String(localized: "Wellenform wird berechnet …"))
            return
        }
        let r = waveRect
        drawWave(a, rate: a.sampleRate, s: m.secPerPoint, t0: m.viewStart, r)
        drawSeams(m, r)
        drawMarks(m, r)
        drawSelection(m, r)
        drawCursor(m, r)
        drawPlayhead(m, r)
        drawRuler(m)
        if let l = loupe { drawLoupe(a, t: l.t, x: l.x, r) }
    }

    private func drawCentered(_ s: String) {
        (s as NSString).draw(at: NSPoint(x: 12, y: bounds.midY - 7),
                             withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(Theme.muted)])
    }

    /// Wellenform: ab 1 Punkt je Sample als Linie durch die Samples (Punkte ab 8 Punkten je Sample), feiner als Hülle je
    /// Punkt aus den Samples, sonst die spitzen der Blöcke des Tracks (schnell auch bei der ganzen Datei)
    private func drawWave(_ a: TrackAudio, rate: Double, s: Double, t0: Double, _ r: NSRect) {
        let mid = r.midY, half = r.height / 2 * 0.92
        let spp = s * rate
        let wave = NSBezierPath()
        wave.lineWidth = 1
        if spp <= 1 {
            let i0 = max(0, Int(floor(t0 * rate))), i1 = min(a.frames - 1, Int(ceil((t0 + Double(r.width) * s) * rate)))
            guard i0 <= i1 else { return }
            let dots = NSBezierPath()
            for i in i0...i1 {
                let p = NSPoint(x: CGFloat((Double(i) / rate - t0) / s), y: mid - CGFloat((a.left[i] + a.right[i]) * 0.5) * half)
                if i == i0 { wave.move(to: p) } else { wave.line(to: p) }
                if spp < 1 / 8 { dots.appendOval(in: NSRect(x: p.x - 2.2, y: p.y - 2.2, width: 4.4, height: 4.4)) }
            }
            NSColor(Theme.bone).withAlphaComponent(0.85).setStroke()
            wave.stroke()
            NSColor(Theme.gold).setFill()
            dots.fill()
            return
        }
        let bf = Double(TrackAudio.blockFrames(sampleRate: rate))
        let W = Int(r.width.rounded(.up))
        if spp < bf {
            for px in 0..<W {
                let f0 = (t0 + Double(px) * s) * rate
                let lo = max(0, Int(f0)), hi = min(a.frames, Int(f0 + spp) + 1)
                guard lo < hi else { continue }
                var mn: Float = 0, mx: Float = 0
                for i in lo..<hi {
                    mn = min(mn, min(a.left[i], a.right[i]))
                    mx = max(mx, max(a.left[i], a.right[i]))
                }
                let x = CGFloat(px)
                wave.move(to: NSPoint(x: x, y: mid - CGFloat(mx) * half))
                wave.line(to: NSPoint(x: x, y: mid - CGFloat(mn) * half))
            }
        } else {
            let peak = a.peak, step = Int(bf)
            for px in 0..<W {
                let f0 = (t0 + Double(px) * s) * rate
                let b0 = Int(f0) / step, b1 = min(peak.count, (Int(f0 + spp)) / step + 1)
                guard b0 < b1 else { continue }
                var pk: Float = 0
                for b in b0..<b1 { pk = max(pk, peak[b]) }
                let x = CGFloat(px)
                wave.move(to: NSPoint(x: x, y: mid - CGFloat(pk) * half))
                wave.line(to: NSPoint(x: x, y: mid + CGFloat(pk) * half))
            }
        }
        NSColor(Theme.bone).withAlphaComponent(0.7).setStroke()
        wave.stroke()
        if spp < 4 { drawSampleGrid(rate: rate, s: s, t0: t0, r) }
    }

    /// Sample-Raster bei mindestens 4 Punkten je Sample
    private func drawSampleGrid(rate: Double, s: Double, t0: Double, _ r: NSRect) {
        let grid = NSBezierPath()
        let i0 = max(0, Int(floor(t0 * rate))), i1 = Int(ceil((t0 + Double(r.width) * s) * rate))
        for i in i0...max(i0, i1) {
            let x = CGFloat((Double(i) / rate - t0) / s)
            grid.move(to: NSPoint(x: x, y: r.minY))
            grid.line(to: NSPoint(x: x, y: r.maxY))
        }
        NSColor(Theme.hairline).setStroke()
        grid.lineWidth = 0.5
        grid.stroke()
    }

    /// Lineal: Zeit je Schritt, bei Samples die Nummer des Samples
    private func drawRuler(_ m: AudioEditMode) {
        let s = m.secPerPoint, t0 = m.viewStart, rate = m.rate
        NSColor(Theme.hairline).setFill()
        NSRect(x: 0, y: rulerH - 1, width: bounds.width, height: 1).fill()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.muted)]
        let end = t0 + Double(bounds.width) * s
        if s * rate <= 1 {
            // Sample-Ebene: Nummer alle k Samples, Abstand mindestens 70 Punkte
            let per = 1 / (s * rate)
            let k = [1, 2, 5, 10, 20, 50, 100, 200, 500].first { Double($0) * per >= 70 } ?? 1000
            var n = (Int(floor(t0 * rate)) / k) * k
            while Double(n) / rate <= end {
                let x = CGFloat((Double(n) / rate - t0) / s)
                if x >= 0 { NSRect(x: x, y: rulerH - 6, width: 1, height: 6).fill() }
                if x >= 0 { ("\(n)" as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: attrs) }
                n += k
            }
            return
        }
        let step = AudioEditView.tickStep(secPerPoint: s)
        var t = (t0 / step).rounded(.up) * step
        while t <= end {
            let x = CGFloat((t - t0) / s)
            NSRect(x: x, y: rulerH - 6, width: 1, height: 6).fill()
            (AudioEditView.clock(t) as NSString).draw(at: NSPoint(x: x + 3, y: 2), withAttributes: attrs)
            t += step
        }
    }

    /// Nähte (Schnitt gold, nur Marke dezent) und Streifen unten: rückwärts gold, Stille und stumm grau
    private func drawSeams(_ m: AudioEditMode, _ r: NSRect) {
        guard let l = m.shown else { return }
        let strip = NSRect(x: 0, y: r.maxY, width: bounds.width, height: stripH)
        let st = l.starts
        for (k, g) in l.segments.enumerated() where g.length > 0 {
            let x0 = CGFloat(m.x(atTime: st[k])), x1 = CGFloat(m.x(atTime: st[k] + g.length))
            let rect = NSRect(x: x0, y: strip.minY + 2, width: max(1, x1 - x0), height: strip.height - 4)
            if g.isSilent {
                NSColor(Theme.muted).withAlphaComponent(0.35).setFill()
                rect.fill()
            } else if g.isReversed {
                NSColor(Theme.gold).withAlphaComponent(0.6).setFill()
                rect.fill()
                if rect.width > 40 { (String(localized: "◀ RÜCK") as NSString).draw(at: NSPoint(x: rect.minX + 4, y: rect.minY), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .foregroundColor: NSColor(Theme.chitin)]) }
            } else if g.muted {
                NSColor(Theme.muted).withAlphaComponent(0.6).setFill()
                rect.fill()
            }
        }
        for (k, t) in l.joints.enumerated() {
            let x = CGFloat(m.x(atTime: t))
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: r.minY))
            line.line(to: NSPoint(x: x, y: r.maxY + stripH))
            line.lineWidth = l.isCut(joint: k) ? 1.5 : 0.5
            (l.isCut(joint: k) ? NSColor(Theme.gold) : NSColor(Theme.muted)).setStroke()
            line.stroke()
        }
    }

    /// Marken (Linie und Name im Lineal) und Bereiche (Band)
    private func drawMarks(_ m: AudioEditMode, _ r: NSRect) {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        for mk in m.marks {
            guard let a = m.outputTime(mk) else { continue }
            let x = CGFloat(m.x(atTime: a))
            if let e = mk.end, let b = m.shown?.outputTime(e) {
                let x0 = CGFloat(m.x(atTime: min(a, b))), x1 = CGFloat(m.x(atTime: max(a, b)))
                NSColor(Theme.gold).withAlphaComponent(0.12).setFill()
                NSRect(x: x0, y: r.minY, width: x1 - x0, height: r.height).fill()
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: 0))
            line.line(to: NSPoint(x: x, y: r.maxY))
            line.lineWidth = 1
            NSColor(Theme.gold).withAlphaComponent(0.85).setStroke()
            line.stroke()
            (mk.name as NSString).draw(at: NSPoint(x: x + 3, y: rulerH - 16), withAttributes: [.font: font, .foregroundColor: NSColor(Theme.gold)])
        }
    }

    private func drawSelection(_ m: AudioEditMode, _ r: NSRect) {
        guard let s = m.selection else { return }
        let x0 = CGFloat(m.x(atTime: s.start)), x1 = CGFloat(m.x(atTime: s.end))
        NSColor(Theme.state).withAlphaComponent(0.22).setFill()
        NSRect(x: x0, y: 0, width: x1 - x0, height: bounds.height).fill()
        NSColor(Theme.state).setFill()
        NSRect(x: x0 - 1, y: 0, width: 2, height: bounds.height).fill()
        NSRect(x: x1 - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    /// Cursor: gestrichelt, Dreieck im Lineal (Einfügen, Start, Marke)
    private func drawCursor(_ m: AudioEditMode, _ r: NSRect) {
        let x = CGFloat(m.x(atTime: m.cursor))
        let line = NSBezierPath()
        line.move(to: NSPoint(x: x, y: 0))
        line.line(to: NSPoint(x: x, y: r.maxY))
        let dash: [CGFloat] = [3, 3]
        line.setLineDash(dash, count: 2, phase: 0)
        line.lineWidth = 1
        NSColor(Theme.bone).setStroke()
        line.stroke()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: x - 5, y: 0))
        tri.line(to: NSPoint(x: x + 5, y: 0))
        tri.line(to: NSPoint(x: x, y: 7))
        tri.close()
        NSColor(Theme.bone).setFill()
        tri.fill()
    }

    private func drawPlayhead(_ m: AudioEditMode, _ r: NSRect) {
        guard m.playing || m.playhead > 0 else { return }
        let x = CGFloat(m.x(atTime: m.playhead))
        NSColor(Theme.gold).setFill()
        NSRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
    }

    /// Lupe: Samples um den Punkt (Mitte = Samplenummer), beim Ziehen einer Auswahlkante
    private func drawLoupe(_ a: TrackAudio, t: Double, x: CGFloat, _ r: NSRect) {
        let w: CGFloat = 220, h: CGFloat = 100, n = 12
        var box = NSRect(x: x + 16, y: rulerH + 6, width: w, height: h)
        if box.maxX > bounds.width { box.origin.x = x - 16 - w }
        NSColor(Theme.chitinRaised).setFill()
        box.fill()
        NSColor(Theme.gold).setStroke()
        NSBezierPath(rect: box).stroke()
        let rate = a.sampleRate, c = AudioEditView.sample(t, rate: rate)
        let pitch = (w - 16) / CGFloat(2 * n)
        let curve = NSBezierPath(), dots = NSBezierPath()
        var first = true
        for i in (c - n)...(c + n) where i >= 0 && i < a.frames {
            let p = NSPoint(x: box.minX + 8 + CGFloat(i - (c - n)) * pitch + pitch / 2,
                            y: box.midY - CGFloat((a.left[i] + a.right[i]) * 0.5) * (h / 2 * 0.8))
            if first { curve.move(to: p); first = false } else { curve.line(to: p) }
            dots.appendOval(in: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
        }
        NSColor(Theme.bone).setStroke()
        curve.stroke()
        NSColor(Theme.gold).setFill()
        dots.fill()
        let mark = NSBezierPath()
        let mx = box.minX + 8 + CGFloat(n) * pitch + pitch / 2
        mark.move(to: NSPoint(x: mx, y: box.minY + 14))
        mark.line(to: NSPoint(x: mx, y: box.maxY - 2))
        NSColor(Theme.state).setStroke()
        mark.stroke()
        (String(localized: "Sample \(c)  ·  \(AudioEditView.clock(t))") as NSString).draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2),
            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor(Theme.muted)])
    }

    // MARK: Maus

    /// Marke im Lineal unter x (höchstens 6 Punkte)
    private func marker(near x: CGFloat, _ m: AudioEditMode) -> AudioMarker? {
        m.marks.first { mk in
            guard let t = m.outputTime(mk) else { return false }
            return abs(CGFloat(m.x(atTime: t)) - x) <= 6
        }
    }

    override func mouseDown(with e: NSEvent) {
        let m = AudioEditMode.shared
        guard m.audio != nil, m.secPerPoint > 0 else { return }
        let p = convert(e.locationInWindow, from: nil)
        let t = m.time(atX: Double(p.x))
        dragMoved = false
        dragShift = e.modifierFlags.contains(.shift)
        if e.clickCount == 2 {
            drag = nil
            if p.y < rulerH, let mk = marker(near: p.x, m) { m.renameMarker(mk.id); return }
            if let seg = m.segmentRange(at: t) { m.setSelection(seg) }   // Doppelklick: das Stück darunter
            return
        }
        if let sel = m.selection {
            let xs = CGFloat(m.x(atTime: sel.start)), xe = CGFloat(m.x(atTime: sel.end))
            if abs(xs - p.x) <= 6 || abs(xe - p.x) <= 6 {
                // Kante ziehen: die andere Kante bleibt
                drag = .edge
                dragAnchor = abs(xe - p.x) < abs(xs - p.x) ? sel.start : sel.end
                loupe = (m.snapped(t), p.x)
                return
            }
        }
        if dragShift {
            // ⇧: von der näheren Kante der Auswahl (sonst vom Cursor) bis hierher
            let anchor = m.selection.map { abs(t - $0.start) < abs(t - $0.end) ? $0.end : $0.start } ?? m.cursor
            drag = .select
            dragAnchor = anchor
            m.setSelection(TrackRange(anchor, m.snapped(t)))
            return
        }
        drag = .select
        dragAnchor = m.snapped(t)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let drag else { return }
        let m = AudioEditMode.shared
        let p = convert(e.locationInWindow, from: nil)
        let v = m.snapped(m.time(atX: Double(p.x)))
        dragMoved = true
        switch drag {
        case .select:
            m.setSelection(TrackRange(dragAnchor, v))
        case .edge:
            m.setSelection(TrackRange(dragAnchor, v))
            loupe = (v, p.x)
        }
    }

    override func mouseUp(with e: NSEvent) {
        let m = AudioEditMode.shared
        if drag == .select, !dragMoved, !dragShift {
            // Klick: Cursor (Deck springt dorthin), Auswahl weg
            let p = convert(e.locationInWindow, from: nil)
            m.setSelection(nil)
            m.setCursor(m.snapped(m.time(atX: Double(p.x))))
        }
        drag = nil
        loupe = nil
        needsDisplay = true
    }

    override func scrollWheel(with e: NSEvent) {
        let m = AudioEditMode.shared
        guard m.secPerPoint > 0 else { return }
        let precise = e.hasPreciseScrollingDeltas
        let dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
        if e.modifierFlags.contains(.shift) || abs(dx) > abs(dy) * 1.5 {
            // horizontal: Trackpad in Punkten, Mausrad in Rasten
            let v = dx != 0 && !e.modifierFlags.contains(.shift) ? dx : dy
            m.scroll(by: -v * m.secPerPoint * (precise ? 1 : 12))
        } else {
            let p = convert(e.locationInWindow, from: nil)
            m.zoom(by: exp(dy * (precise ? 0.012 : 0.25)), at: m.time(atX: Double(p.x)), x: Double(p.x))
        }
    }

    override func magnify(with event: NSEvent) {
        let m = AudioEditMode.shared
        let p = convert(event.locationInWindow, from: nil)
        m.zoom(by: exp(Double(event.magnification)), at: m.time(atX: Double(p.x)), x: Double(p.x))
    }
}

/// Werkzeugzeile des Editors: Abspielen, Ansicht, Raster, Bearbeiten (über die Schnittliste), Marken, Rückgängig
struct AudioEditToolbar: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let m = AudioEditMode.shared
        let _ = m.selection
        let _ = m.snap
        let playing = mix.deck(AudioEditMode.deck).playing
        VStack(alignment: .leading, spacing: 4.z) {
            HStack(spacing: 4.z) {
                DeckButton(title: playing ? String(localized: "■ STOP") : String(localized: "▶ SPACE"), active: playing, compact: true) { m.playToggle() }
                DeckButton(title: "−", compact: true) { m.zoomKey(1 / AudioEditView.zoomStep) }
                DeckButton(title: "+", compact: true) { m.zoomKey(AudioEditView.zoomStep) }
                DeckButton(title: String(localized: "ALLES"), compact: true) { m.fitView() }
                DeckButton(title: String(localized: "AUF AUSWAHL"), compact: true) { m.zoomToSelection() }
                sep
                DeckButton(title: String(localized: "RASTER"), active: m.snap, compact: true) { m.snapToggle() }
                sep
                DeckButton(title: String(localized: "LÖSCHEN ⌫"), compact: true) { m.delete() }
                DeckButton(title: String(localized: "NUR AUSWAHL ⌥⌫"), compact: true) { m.crop() }
                DeckButton(title: String(localized: "STILLE I"), compact: true) { m.silence() }
                DeckButton(title: String(localized: "RÜCKWÄRTS R"), compact: true) { m.reverse() }
                sep
                DeckButton(title: String(localized: "AUSSCHNEIDEN ⌘X"), compact: true) { m.cut() }
                DeckButton(title: String(localized: "KOPIEREN ⌘C"), compact: true) { m.copy() }
                DeckButton(title: String(localized: "EINFÜGEN ⌘V"), compact: true) { m.paste() }
                sep
                DeckButton(title: String(localized: "MARKE M"), compact: true) { m.addMarker(range: false) }
                DeckButton(title: String(localized: "BEREICH → MARKE"), compact: true) { m.addMarker(range: true) }
                Spacer(minLength: 0)
                DeckButton(title: String(localized: "↶ ⌘Z"), compact: true) { UndoStack.shared.perform(redo: false) }
                DeckButton(title: String(localized: "↷ ⇧⌘Z"), compact: true) { UndoStack.shared.perform(redo: true) }
            }
            AudioEditReadout()
        }
        .padding(.horizontal, 8.z).padding(.vertical, 6.z)
    }

    private var sep: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16.z) }
}

/// Felder der Auswahl und des Cursors: Anfang, Ende, Länge in m:ss.mmm und in Samples, editierbar (Enter übernimmt)
struct AudioEditReadout: View {
    @Environment(MixModel.self) private var mix
    @State private var start = ""
    @State private var end = ""
    @State private var length = ""
    @State private var sStart = ""
    @State private var sEnd = ""
    @State private var sLength = ""
    @State private var cursor = ""

    var body: some View {
        let m = AudioEditMode.shared
        let _ = m.selection
        let _ = m.cursor
        HStack(spacing: 8.z) {
            Text(verbatim: String(localized: "AUSWAHL")).font(Theme.label(9.z)).foregroundStyle(Theme.muted)
            field(String(localized: "ANFANG"), $start, 96) { if let t = AudioEditView.parse(start) { setRange(start: t) } }
            field(String(localized: "ENDE"), $end, 96) { if let t = AudioEditView.parse(end) { setRange(end: t) } }
            field(String(localized: "LÄNGE"), $length, 96) { if let t = AudioEditView.parse(length) { setRange(length: t) } }
            Text(verbatim: String(localized: "SAMPLES")).font(Theme.label(9.z)).foregroundStyle(Theme.muted)
            field("", $sStart, 72) { if let n = Int(sStart) { setRange(start: AudioEditView.time(n, rate: m.rate)) } }
            field("", $sEnd, 72) { if let n = Int(sEnd) { setRange(end: AudioEditView.time(n, rate: m.rate)) } }
            field("", $sLength, 72) { if let n = Int(sLength) { setRange(length: AudioEditView.time(n, rate: m.rate)) } }
            Spacer(minLength: 0)
            Text(verbatim: String(localized: "CURSOR")).font(Theme.label(9.z)).foregroundStyle(Theme.muted)
            field("", $cursor, 96) { if let t = AudioEditView.parse(cursor) { m.setCursor(t) } }
        }
        .onAppear(perform: sync)
        .onChange(of: m.selection) { _, _ in sync() }
        .onChange(of: m.cursor) { _, _ in sync() }
        .onChange(of: m.revision) { _, _ in sync() }
        .onChange(of: mix.deck(AudioEditMode.deck).duration) { _, _ in sync() }
    }

    private func field(_ title: String, _ text: Binding<String>, _ w: CGFloat, commit: @escaping () -> Void) -> some View {
        HStack(spacing: 4.z) {
            if !title.isEmpty { Text(verbatim: title).font(Theme.mono(8.z)).foregroundStyle(Theme.muted) }
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(Theme.mono(11.z))
                .frame(width: w.z)
                .padding(.horizontal, 4.z).padding(.vertical, 2.z)
                .background(Theme.chitinRaised)
                .onSubmit { commit(); sync() }
        }
    }

    /// Anzeige aus dem Modus (Auswahl oder Cursor)
    private func sync() {
        let m = AudioEditMode.shared
        if let r = m.selection {
            let s = AudioEditView.samples(r, rate: m.rate)
            start = AudioEditView.clock(r.start)
            end = AudioEditView.clock(r.end)
            length = AudioEditView.clock(r.length)
            sStart = "\(s.start)"
            sEnd = "\(s.end)"
            sLength = "\(s.length)"
        } else {
            start = "–"; end = "–"; length = "–"
            sStart = "–"; sEnd = "–"; sLength = "–"
        }
        cursor = AudioEditView.clock(m.cursor)
    }

    private func setRange(start s: Double? = nil, end e: Double? = nil, length l: Double? = nil) {
        let m = AudioEditMode.shared
        let base = m.selection ?? TrackRange(m.cursor, m.cursor)
        var a = base.start, b = base.end
        if let s { a = s }
        if let e { b = e }
        if let l { b = a + l }
        m.setSelection(TrackRange(a, b))
    }
}

/// Marken des Tracks: Zeit, Name (Doppelklick = umbenennen), Klick = springen, ✕ = löschen
struct AudioEditMarkers: View {
    var body: some View {
        let m = AudioEditMode.shared
        let _ = m.marks
        let _ = m.revision
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6.z) {
                Text(verbatim: String(localized: "MARKEN")).font(Theme.label(10.z))
                Text(verbatim: "\(m.marks.count)").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                Spacer(minLength: 4.z)
                DeckButton(title: String(localized: "+ CURSOR"), compact: true) { m.addMarker(range: false) }
            }
            .padding(.horizontal, 8.z).padding(.vertical, 5.z)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if m.marks.isEmpty {
                Text(verbatim: String(localized: "keine Marken – M setzt eine am Cursor"))
                    .font(Theme.mono(10.z)).foregroundStyle(Theme.muted).padding(8.z)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(m.marks) { mk in row(mk, m) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ mk: AudioMarker, _ m: AudioEditMode) -> some View {
        let t = m.outputTime(mk)
        return HStack(spacing: 6.z) {
            Text(verbatim: t.map { AudioEditView.clock($0) } ?? "–")
                .font(Theme.mono(10.z)).foregroundStyle(t == nil ? Theme.muted : Theme.bone).frame(width: 84.z, alignment: .leading)
            Text(verbatim: mk.name + (mk.end == nil ? "" : " ⟷"))
                .font(Theme.mono(11.z)).foregroundStyle(Theme.gold).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(TapGesture(count: 2).onEnded { m.renameMarker(mk.id) }.exclusively(before: TapGesture().onEnded { m.jumpMarker(mk.id) }))
            Button { m.deleteMarker(mk.id) } label: { Text(verbatim: "✕").font(Theme.mono(10.z)) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8.z).padding(.vertical, 4.z)
    }
}

/// Schritte der Rückgängig-Liste, neueste oben; Klick springt zum Schritt (zurück oder wieder vor)
struct AudioEditHistory: View {
    var body: some View {
        let steps = UndoStack.shared.timeline
        let doneCount = steps.filter { !$0.undone }.count
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6.z) {
                Text(verbatim: String(localized: "SCHRITTE")).font(Theme.label(10.z))
                Text(verbatim: "\(doneCount)/\(steps.count)").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8.z).padding(.vertical, 5.z)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if steps.isEmpty {
                Text(verbatim: String(localized: "noch keine Schritte")).font(Theme.mono(10.z)).foregroundStyle(Theme.muted).padding(8.z)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(steps.enumerated().reversed()), id: \.offset) { i, s in
                            let current = !s.undone && i == doneCount - 1
                            HStack(spacing: 6.z) {
                                Text(verbatim: s.wall.formatted(date: .omitted, time: .standard))
                                    .font(Theme.mono(9.z)).foregroundStyle(Theme.muted).frame(width: 64.z, alignment: .leading)
                                Text(verbatim: s.label).font(Theme.mono(10.z))
                                    .foregroundStyle(s.undone ? Theme.muted : current ? Theme.gold : Theme.bone).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8.z).padding(.vertical, 3.z)
                            .background(current ? Theme.state.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { UndoStack.shared.jump(to: i) }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
