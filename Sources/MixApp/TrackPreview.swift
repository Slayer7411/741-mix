import AppKit
import os
import SwiftUI
import MixCore
import MixEngine

/// Browser-Vorschau: wo die Mini-Übersicht (Wellenform + Grid + Cues) steht
enum PreviewMode: String, CaseIterable, Codable, Identifiable {
    case fullRow = "Ganze Zeile (zweizeilig)", column = "Eigene Spalte", behindTitle = "Hinter dem Titel", off = "Aus"
    var id: String { rawValue }
}

/// Breite des Bandes (Modus „ganze Zeile“): nur die sichtbare Breite der Tabelle (bleibt beim Scrollen am Platz) oder ganze Zeile
enum PreviewBandSpan: String, CaseIterable, Codable, Identifiable {
    case visible = "Sichtbare Breite", row = "Ganze Zeile"
    var id: String { rawValue }
}

/// Farben der Browser-Vorschau: Spektrum (rot = Bass, grün = Mitten, blau = Höhen) oder wie die Deck-Wellenform
enum PreviewColors: String, CaseIterable, Codable, Identifiable {
    case spectrum = "Spektrum (rot/grün/blau)", waveform = "wie Wellenform"
    var id: String { rawValue }
}

/// Vorschauen im Hintergrund berechnen
enum PreviewFill: String, CaseIterable, Codable, Identifiable {
    case always = "immer (gedrosselt)", idleOnly = "nur wenn kein Deck spielt", off = "aus"
    var id: String { rawValue }
    var mode: OverviewPolicy.Mode {
        switch self {
        case .always: .always
        case .idleOnly: .idleOnly
        case .off: .off
        }
    }
}

/// Übersichten aller Tracks: Speicher, Nachrechnen (Deck, Stapel, sichtbare Zeilen, Hintergrund) und ein gedrosselter
/// Zähler, an dem die sichtbaren Vorschau-Zellen hängen. Regeln: `OverviewPolicy`, Arbeiter: `OverviewJobs`.
@MainActor @Observable
final class Overviews {
    static let shared = Overviews()

    /// Selbsttest/Messung: eigener Ordner (MIX741_OVERVIEW_DIR, sonst temporär) – nie Christians Cache
    nonisolated static let directory: URL = {
        if Session.isSelfTest {
            if let d = ProcessInfo.processInfo.environment["MIX741_OVERVIEW_DIR"] { return URL(fileURLWithPath: d, isDirectory: true) }
            return FileManager.default.temporaryDirectory.appendingPathComponent("minos-overviews-\(getpid())")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MINOS-741/overviews")   // = HistoryStore.baseDir
    }()

    @ObservationIgnored let store = OverviewStore(directory: Overviews.directory)
    @ObservationIgnored let jobs = OverviewJobs()
    /// zählt hoch, wenn Übersichten neu sind oder Grids sich ändern (höchstens 2× je Sekunde)
    private(set) var tick = 0
    private(set) var loaded = false
    /// Stand für die Statuszeile
    private(set) var progress = OverviewJobs.Progress()
    /// ✕ in der Statuszeile: Hintergrund bis zum nächsten Start (oder bis die Einstellung wechselt) angehalten
    private(set) var stopped = false
    @ObservationIgnored private var tickPending = false
    /// Stapel (Rechtsklick): abgebrochen, nicht lesbare Dateien am Anfang
    @ObservationIgnored private var batchCancelled = false
    @ObservationIgnored private var batchFailed = 0

    private init() {
        let store = store, jobs = jobs
        store.onChange = { key in
            jobs.stored(key)
            DispatchQueue.main.async { MainActor.assumeIsolated { Overviews.shared.bump() } }
        }
        jobs.store = store
        jobs.onProgress = { p in
            DispatchQueue.main.async { MainActor.assumeIsolated { Overviews.shared.report(p) } }
        }
        DispatchQueue.global(qos: .utility).async {
            store.load()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let o = Overviews.shared
                    o.loaded = true
                    o.jobs.start()
                    o.bump()
                }
            }
        }
    }

    /// Stapel: Stand in der Statusleiste (mit Track und ✕), am Ende eine Meldung
    private func report(_ p: OverviewJobs.Progress) {
        let old = progress
        if old.total == 0, p.total > 0 { batchCancelled = false; batchFailed = p.failed }
        if old != p { progress = p }
        if p.total > 0 {
            let frac = Double(p.done) / Double(max(1, p.total))
            StatusCenter.post(.info, String(localized: "Vorschauen berechnen"), detail: p.current.isEmpty ? nil : p.current, key: "overview",
                              progress: frac, progressText: "\(p.done)/\(p.total) · \(Int(frac * 100)) %", job: true,
                              cancel: { Overviews.shared.cancel() })
        } else if old.total > 0 {
            let failed = p.failed - batchFailed
            if batchCancelled {
                StatusCenter.post(.info, String(localized: "Vorschauen abgebrochen"), key: "overview")
            } else {
                var msg = String(localized: "Vorschauen fertig: \(old.done) Tracks")
                if failed > 0 { msg += " · " + String(localized: "\(failed) nicht lesbar") }
                StatusCenter.post(failed > 0 ? .warning : .ok, msg, key: "overview")
            }
        }
    }

    /// sichtbare Zellen neu zeichnen lassen (gedrosselt)
    func bump() {
        guard !tickPending else { return }
        tickPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated {
                self.tickPending = false
                self.tick += 1
            }
        }
    }

    /// Track liegt auf einem Deck: Übersicht aus den schon berechneten Wellenform-Blöcken (kostet nichts)
    func ingest(_ t: Track, audio: TrackAudio) {
        let store = store
        DispatchQueue.global(qos: .utility).async {
            guard !store.isValid(t.key, path: t.path) else { return }
            store.put(t.key, path: t.path, overview: TrackOverview(audio: audio))
        }
    }

    /// Rechtsklick → Vorschauen berechnen
    func enqueue(_ tracks: [Track]) {
        jobs.enqueue(tracks.filter { !$0.path.isEmpty }.map { .init(key: $0.key, path: $0.path, explicit: true, label: StatusCenter.trackName($0)) })
    }

    /// sichtbare Zeile ohne Übersicht -> vor den Hintergrund
    func want(_ t: Track) {
        guard !stopped, !t.loose, t.fileExists else { return }
        jobs.want(key: t.key, path: t.path)
    }

    func cancel() {
        batchCancelled = true
        jobs.cancel()
    }

    /// ✕ ohne Stapel: Hintergrund anhalten
    func stop() {
        stopped = true
        jobs.stopBackground()
    }

    func setMode(_ f: PreviewFill) {
        stopped = false
        jobs.setMode(f.mode)
    }

    /// Hintergrund-Liste neu: Collection-Tracks ohne Übersicht, neueste zuerst; reine Cloud-Dateien nur gezählt
    func updateBackground(on: Bool, tracks: [Track]) {
        guard on, !stopped else { jobs.setBackground([], collection: 0, covered: 0, onlineOnly: 0); return }
        let store = store, jobs = jobs
        DispatchQueue.global(qos: .utility).async {
            let files = tracks.filter { !$0.loose && $0.fileExists && !$0.path.isEmpty }
            var missing: [Track] = [], online = 0
            for t in files where !store.contains(t.key) {
                if OverviewPolicy.fileState(path: t.path) == .onlineOnly { online += 1 } else { missing.append(t) }
            }
            missing.sort { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
            jobs.setBackground(missing.map { .init(key: $0.key, path: $0.path, explicit: false) },
                               collection: files.count, covered: files.count - missing.count - online, onlineOnly: online)
        }
    }

    func setDecks(playing: Bool, loading: Bool) { jobs.setDecks(playing: playing, loading: loading) }
}

// MARK: - Zeichnen

/// Alles, was eine Vorschau bestimmt – Hash = Schlüssel im Bild-Cache
struct PreviewSpec: Hashable, Sendable {
    struct Mark: Hashable, Sendable { var t: Double; var r: UInt8, g: UInt8, b: UInt8; var number = 0 }
    /// Loop (Hotcue-Loop oder gespeicherter Loop): Band über die Länge
    struct LoopMark: Hashable, Sendable { var t: Double; var len: Double; var r: UInt8, g: UInt8, b: UInt8 }
    var key: String
    var path: String
    /// Generation der gespeicherten Übersicht (0 = keine)
    var gen: Int
    var duration: Double
    var bpm: Double
    var anchor: Double
    var phraseBeats: Int
    var cues: [Mark]
    var loops: [LoopMark] = []
    var start: Mark?
    /// Schnitt (s): davor / dahinter gedimmt, Ränder markiert
    var cutStart: Double?
    var cutEnd: Double?
    var palette: WaveformPalette
    /// Farben Tief / Mitte / Hoch „wie Wellenform“ (r, g, b je Band): 3-Band aus dem Preset, sonst aus `palette`
    var tint: [Float]
    var style: WaveformStyle
    var colors: PreviewColors
    /// ganze Zeile: breiteres Bild
    var wide = false

    /// Track mit den eigenen Grid-/Cue-Änderungen (wie beim Laden ins Deck)
    @MainActor init(_ track: Track, mix: MixModel) {
        let e = mix.edits.edit(for: track.key)
        let t = e?.apply(to: track) ?? track
        self.init(t, ui: mix.prefs.ui, controller: mix.prefs.controller, info: Overviews.shared.store.info(t.key), trim: e?.trim,
                  preset: mix.wavePreset)
    }

    /// ohne Modell (Selbsttest-Bilder): Übersicht direkt übergeben
    init(_ t: Track, ui: UIPrefs, controller: ControllerPrefs, overview: TrackOverview, trim: TrackTrim? = nil) {
        self.init(t, ui: ui, controller: controller, info: (gen: 1, duration: overview.duration), trim: trim,
                  preset: WavePresetList(builtIn: WavePresets.builtIn).resolved(ui.wavePreset))
    }

    /// Farben der Vorschau „wie Wellenform“: 3-Band aus dem Preset (RGB direkt = Spektrum-Palette), sonst die Palette
    static func tint(_ ui: UIPrefs, preset: WavePreset) -> [Float] {
        if ui.waveformStyle == .blend, !preset.look.direct {
            return [preset.look.low, preset.look.mid, preset.look.high].flatMap { [$0.r, $0.g, $0.b] }
        }
        let c = RenderedWaveform.Colors.of(ui.waveformStyle == .blend ? .rgb : ui.waveformPalette)
        return [c.low, c.mid, c.high].flatMap { [Float($0.r), Float($0.g), Float($0.b)] }
    }

    private init(_ t: Track, ui: UIPrefs, controller c: ControllerPrefs, info: (gen: Int, duration: Double)?, trim: TrackTrim?, preset: WavePreset) {
        key = t.key
        path = t.path
        gen = info?.gen ?? 0
        duration = info?.duration ?? t.duration
        if let trim, !trim.isEmpty {
            let cut = PreviewCut(trim: trim, duration: duration)
            cutStart = cut.cutStart ? cut.lo : nil
            cutEnd = cut.cutEnd ? cut.hi : nil
        }
        let grid = BeatGrid(track: t)
        let tempo = grid?.bpm ?? 0
        bpm = tempo
        anchor = grid?.anchor ?? 0
        phraseBeats = max(4, ui.phraseBeats)
        palette = ui.waveformPalette
        tint = Self.tint(ui, preset: preset)
        style = ui.waveformStyle
        colors = ui.previewColors
        let startMs = Theme.startCueMs(t)
        let mark = { (ms: Double, p: PadColor) in Mark(t: ms / 1000, r: p.rgb.r, g: p.rgb.g, b: p.rgb.b) }
        cues = t.hotcues.map { h in var m = mark(h.startMs, c.color(for: h, startMs: startMs, bpm: tempo)); m.number = h.hotcue + 1; return m }
        // Loops: Hotcue-Loops in ihrer Farbe, gespeicherte (Memory) grün
        loops = t.cues.filter { $0.kind == .loop && $0.lengthMs > 0 }.map { l in
            let p = l.hotcue >= 0 ? c.color(for: l, startMs: startMs, bpm: tempo).rgb : (r: UInt8(30), g: UInt8(120), b: UInt8(50))
            return LoopMark(t: l.startMs / 1000, len: l.lengthMs / 1000, r: p.r, g: p.g, b: p.b)
        }
        start = startMs.map { mark($0, c.colorStartCue) }
    }
}

enum PreviewRenderer {
    /// Bildgröße in Pixeln (2×): 200 × 17 pt, die Zelle streckt es auf ihre Breite
    static let width = 400, height = 34
    /// ganze Zeile (zweizeilig): Band über alle Spalten
    static let wideWidth = 1000
    static let heightPt: CGFloat = 17

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let bone = rgb(230 / 255, 225 / 255, 218 / 255, 1)
    static let lila = rgb(150 / 255, 70 / 255, 210 / 255, 1)
    static let magenta = rgb(0.88, 0.22, 0.78, 1)
    static let void = rgb(10 / 255, 9 / 255, 8 / 255, 0.9)
    /// außerhalb des Schnitts: Schwarz mit dieser Deckkraft darüber (wie Deck-Wellenform und -Übersicht)
    static let cutDim: CGFloat = 0.62
    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Spektrum-Farben: immer die klassische Palette (rot = Bass, grün = Mitten, blau = Höhen), unabhängig vom Deck
    private static let spectrumColors: (OverviewPaint.RGB, OverviewPaint.RGB, OverviewPaint.RGB) = {
        let c = RenderedWaveform.Colors.of(.classic)
        let f = { (x: RenderedWaveform.RGB) in OverviewPaint.RGB(Float(x.r), Float(x.g), Float(x.b)) }
        return (f(c.low), f(c.mid), f(c.high))
    }()

    /// je Spalte eine deckende Farbe (Bänder additiv, gesättigt), Höhe aus der Energie; helle Linie an großen Sprüngen
    private static func drawSpectrum(_ ctx: CGContext, _ o: TrackOverview, width w: Int, height h: Int, pps: CGFloat) {
        let mid = CGFloat(h) / 2, amp = mid - 1
        let span = CGFloat(o.duration) * pps   // Übersicht deckt die ganze Datei ab
        let n = min(w, Int(span.rounded(.up)))
        guard n > 0 else { return }
        let (lo, mi, hi) = spectrumColors
        let cols = OverviewPaint.columns(o, width: n, low: lo, mid: mi, high: hi)
        for (x, c) in cols.enumerated() {
            let a = max(0.5, CGFloat(c.amp) * amp)
            ctx.setFillColor(rgb(CGFloat(c.color.r), CGFloat(c.color.g), CGFloat(c.color.b), 1))
            ctx.fill(CGRect(x: CGFloat(x) * span / CGFloat(n), y: mid - a, width: max(1, span / CGFloat(n)), height: 2 * a))
        }
        ctx.setFillColor(bone.copy(alpha: 0.85)!)
        ctx.fill(OverviewPaint.drops(o).map { CGRect(x: CGFloat($0) * span - 0.75, y: 0, width: 1.5, height: CGFloat(h)) })
    }

    /// Schnitt: davor / dahinter gedimmt (nur Gezeichnetes, die Zeile darunter bleibt), Ränder als Linie mit
    /// Laschen oben und unten nach außen – wie die Griffe der Deck-Übersicht, hier nur Markierung
    private static func drawCut(_ ctx: CGContext, _ s: PreviewSpec, pps: CGFloat, width W: CGFloat, height H: CGFloat) {
        guard s.cutStart != nil || s.cutEnd != nil else { return }
        let x0 = CGFloat(s.cutStart ?? 0) * pps, x1 = CGFloat(s.cutEnd ?? 0) * pps
        ctx.saveGState()
        ctx.setBlendMode(.sourceAtop)
        ctx.setFillColor(rgb(0, 0, 0, cutDim))
        if s.cutStart != nil { ctx.fill(CGRect(x: 0, y: 0, width: x0, height: H)) }
        if s.cutEnd != nil { ctx.fill(CGRect(x: x1, y: 0, width: W - x1, height: H)) }
        ctx.restoreGState()
        let lw: CGFloat = 2, tab = 4 * H / 18
        ctx.setFillColor(bone)
        for (x, set, out) in [(x0, s.cutStart != nil, true), (x1, s.cutEnd != nil, false)] where set {
            let lx = min(max(0, x - lw / 2), W - lw)
            ctx.fill(CGRect(x: lx, y: 0, width: lw, height: H))
            ctx.fill(CGRect(x: out ? lx - tab : lx, y: 0, width: tab + lw, height: tab))
            ctx.fill(CGRect(x: out ? lx - tab : lx, y: H - tab, width: tab + lw, height: tab))
        }
    }

    /// Mini-Übersicht: Phrasen-Bänder, 3-Band-Wellenform (gedämpft), Marker alle 16/32 Takte, Hotcues, Start-Cue
    static func render(_ s: PreviewSpec, overview: TrackOverview?) -> CGImage? {
        let w = s.wide ? wideWidth : width, h = height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let W = CGFloat(w), H = CGFloat(h), mid = H / 2
        let dur = overview?.duration ?? s.duration
        guard dur > 0 else { return ctx.makeImage() }
        let pps = W / dur
        // Grid: Phrasen-Bänder (jede zweite Phrase), Marker alle 16 / 32 Takte
        if s.bpm > 0, s.bpm.isFinite {
            let g = BeatGrid(anchor: s.anchor, bpm: s.bpm)
            let first = Int(g.beatPosition(at: 0).rounded(.down)), last = Int(g.beatPosition(at: dur).rounded(.up))
            if last > first, last - first < 20_000 {
                let ph = s.phraseBeats
                var bands: [CGRect] = [], m16: [CGRect] = [], m32: [CGRect] = []
                var p = Int((Double(first) / Double(ph)).rounded(.down)) * ph
                while p <= last {
                    if ((p / ph) % 2 + 2) % 2 == 1 {
                        let x0 = g.time(ofBeat: Double(p)) * pps, x1 = g.time(ofBeat: Double(p + ph)) * pps
                        bands.append(CGRect(x: x0, y: 0, width: x1 - x0, height: H))
                    }
                    p += ph
                }
                var b = Int((Double(first) / 64).rounded(.down)) * 64
                while b <= last {
                    let x = g.time(ofBeat: Double(b)) * pps
                    if x >= 0, x <= W {
                        if (b / 4) % 32 == 0 { m32.append(CGRect(x: x - 0.75, y: 0, width: 1.5, height: H)) }
                        else { m16.append(CGRect(x: x - 0.5, y: 0, width: 1, height: H)) }
                    }
                    b += 64
                }
                // Spektrum: Grid zurückhaltend, damit die Farben tragen
                let spectrum = s.colors == .spectrum
                ctx.setFillColor(lila.copy(alpha: spectrum ? 0.09 : 0.16)!); ctx.fill(bands)
                ctx.setFillColor(bone.copy(alpha: spectrum ? 0.14 : 0.28)!); ctx.fill(m16)
                ctx.setFillColor(magenta.copy(alpha: spectrum ? 0.4 : 0.7)!); ctx.fill(m32)
            }
        }
        if let o = overview, o.count > 0, s.colors == .spectrum {
            drawSpectrum(ctx, o, width: w, height: h, pps: pps)
        } else if let o = overview, o.count > 0 {
            // wie Wellenform (gedämpft, Farben aus den Einstellungen)
            let band = { (i: Int) in RenderedWaveform.RGB(r: CGFloat(s.tint[i * 3]), g: CGFloat(s.tint[i * 3 + 1]), b: CGFloat(s.tint[i * 3 + 2])) }
            let colors = (low: band(0), mid: band(1), high: band(2))
            let cg = { (c: RenderedWaveform.RGB) in rgb(c.r, c.g, c.b, 0.6) }
            var lo: [CGRect] = [], mi: [CGRect] = [], hi: [CGRect] = []
            lo.reserveCapacity(w); mi.reserveCapacity(w); hi.reserveCapacity(w)
            let amp = mid - 1
            // laut gemasterte Tracks liegen fast überall bei 0 dBFS: je Track normieren und spreizen, Umriss aus dem
            // Bass-Anteil -> Intro, Break und Drop heben sich ab
            var top: Float = 0.001
            for i in 0..<o.count { top = max(top, o.peak(i)) }
            let level = { (i: Int) in CGFloat(pow(o.peak(i) / top, 2.5)) }
            let span = CGFloat(o.duration) * pps   // Übersicht deckt die ganze Datei ab
            for x in 0..<Int(span.rounded(.up)) where x < w {
                let i = min(o.count - 1, Int(CGFloat(x) / span * CGFloat(o.count)))
                let pk = level(i)
                let bar = { (a: CGFloat) in CGRect(x: CGFloat(x), y: mid - max(0.5, a * amp), width: 1, height: max(1, 2 * a * amp)) }
                switch s.style {
                case .blend:
                    lo.append(bar(pk * (0.35 + 0.65 * CGFloat(o.low(i)).squareRoot())))
                    mi.append(bar(pk * 0.7 * CGFloat(o.mid(i) + o.high(i)).squareRoot()))
                    hi.append(bar(pk * 0.6 * RenderedWaveform.highLevel(o.high(i))))
                case .mono, .spectrum:
                    mi.append(bar(pk * (0.35 + 0.65 * CGFloat(o.low(i)).squareRoot())))
                }
            }
            ctx.setFillColor(cg(colors.low)); ctx.fill(lo)
            ctx.setFillColor(cg(colors.mid)); ctx.fill(mi)
            ctx.setFillColor(cg(colors.high)); ctx.fill(hi)
        } else {
            // ohne Übersicht: nur eine feine Mittellinie (Grid und Cues tragen die Vorschau)
            ctx.setFillColor(bone.copy(alpha: 0.12)!)
            ctx.fill(CGRect(x: 0, y: mid - 0.5, width: W, height: 1))
        }
        // Loops: getöntes Band über die Länge, kräftiger Rand oben
        for l in s.loops {
            let x0 = l.t * pps, w = max(2, l.len * pps)
            let r = CGFloat(l.r) / 127, g = CGFloat(l.g) / 127, b = CGFloat(l.b) / 127
            ctx.setFillColor(rgb(r, g, b, 0.28))
            ctx.fill(CGRect(x: x0, y: 0, width: w, height: H))
            ctx.setFillColor(rgb(r, g, b, 1))
            ctx.fill(CGRect(x: x0, y: H - 3, width: w, height: 3))
        }
        // Hotcues: farbige Striche, dunkler Rand (weiße Cues auf heller Wellenform), Nummer bei genug Höhe
        ctx.setFillColor(void)
        ctx.fill(s.cues.map { CGRect(x: $0.t * pps - 2.5, y: H * 0.4, width: 5, height: H * 0.6) })
        for c in s.cues {
            ctx.setFillColor(rgb(CGFloat(c.r) / 127, CGFloat(c.g) / 127, CGFloat(c.b) / 127, 1))
            ctx.fill(CGRect(x: c.t * pps - 1.5, y: H * 0.4, width: 3, height: H * 0.6))
        }
        if H >= 30 {
            for c in s.cues where c.number > 0 {
                let box = CGRect(x: c.t * pps + 1.5, y: H - 13, width: 9, height: 12)
                ctx.setFillColor(rgb(CGFloat(c.r) / 127, CGFloat(c.g) / 127, CGFloat(c.b) / 127, 1))
                ctx.fill(box)
                let str = NSAttributedString(string: "\(c.number)", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
                                                                                 .foregroundColor: NSColor.black])
                let line = CTLineCreateWithAttributedString(str)
                ctx.textPosition = CGPoint(x: box.minX + 1.5, y: box.minY + 2.5)
                CTLineDraw(line, ctx)
            }
        }
        if let st = s.start {
            let x = st.t * pps
            ctx.setFillColor(rgb(CGFloat(st.r) / 127, CGFloat(st.g) / 127, CGFloat(st.b) / 127, 1))
            ctx.move(to: CGPoint(x: x - 5, y: H)); ctx.addLine(to: CGPoint(x: x + 5, y: H)); ctx.addLine(to: CGPoint(x: x, y: H - 8))
            ctx.closePath(); ctx.fillPath()
        }
        drawCut(ctx, s, pps: pps, width: W, height: H)
        return ctx.makeImage()
    }
}

/// fertige Vorschau-Bilder (NSCache, nach Bytes begrenzt) + Zeichnen im Hintergrund
enum PreviewImages {
    nonisolated(unsafe) static let cache: NSCache<NSNumber, CGImage> = {
        let c = NSCache<NSNumber, CGImage>()
        c.totalCostLimit = 48 << 20   // ~48 MB ≈ 900 Bilder
        return c
    }()
    private static let queue = DispatchQueue(label: "minos741.preview", qos: .userInitiated, attributes: .concurrent)

    static func cached(_ h: Int) -> CGImage? { cache.object(forKey: NSNumber(value: h)) }

    static func render(_ s: PreviewSpec) async -> CGImage? {
        let store = await Overviews.shared.store
        return await withCheckedContinuation { cont in
            queue.async {
                let ov = s.gen > 0 ? store.overview(s.key, path: s.path) : nil
                let img = PreviewRenderer.render(s, overview: ov)
                if let img { cache.setObject(img, forKey: NSNumber(value: s.hashValue), cost: img.bytesPerRow * img.height) }
                cont.resume(returning: img)
            }
        }
    }
}

/// Zelle: Bild aus dem Cache, sonst im Hintergrund zeichnen und nachreichen. Keine Arbeit je Frame.
struct TrackPreviewCell: View {
    /// ausdrücklich übergeben: Tabellenzellen bekommen die Umgebung nicht in jedem Fall (Vorab-Messung der Zeilen)
    let mix: MixModel
    let track: Track
    /// hinter dem Titel: Höhe der Zeile füllen
    var fill = false
    @State private var image: CGImage?
    @State private var imageHash = 0

    var body: some View {
        let _ = Overviews.shared.tick
        let spec = PreviewSpec(track, mix: mix)
        let h = spec.hashValue
        let img = PreviewImages.cached(h) ?? (imageHash == h ? image : nil)
        ZStack {
            if let img { Image(decorative: img, scale: 2).resizable().interpolation(.medium) }
            // hinter dem Titel: nur der Strich, der Klick bleibt beim Titel
            if mix.previewing?.key == track.key { PreviewPlayhead(mix: mix, key: track.key, seeks: !fill) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: fill ? nil : PreviewRenderer.heightPt.z)
        .frame(maxHeight: fill ? .infinity : nil)
        .task(id: h) {
            // sichtbar ohne Übersicht: vor den Hintergrund ziehen
            if spec.gen == 0 { Overviews.shared.want(track) }
            guard PreviewImages.cached(h) == nil else { return }
            let r = await PreviewImages.render(spec)
            image = r
            imageHash = h
        }
        .accessibilityHidden(true)
    }
}

/// Vorhören dieses Tracks: Position als Strich (10 Hz, nur diese eine Zelle), Klick springt – außerhalb des
/// Schnitts an den nächsten Rand innen
struct PreviewPlayhead: View {
    let mix: MixModel
    let key: String
    var seeks = true

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                Canvas { ctx, size in
                    guard let f = mix.previewFraction, f.isFinite else { return }
                    ctx.fill(Path(CGRect(x: CGFloat(f) * size.width - 1, y: 0, width: 2, height: size.height)), with: .color(Theme.state))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in mix.seekPreview(key, fraction: p.x / max(1, geo.size.width)) }
            .allowsHitTesting(seeks)
        }
    }
}

/// Statuszeile: Vorhören läuft – Restzeit bis zum Schnitt-Ende / Länge des Schnitts, lädt noch; ✕ hält an
struct PreviewPlayStatus: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        if let v = mix.previewing {
            HStack(spacing: 4.z) {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let rest = v.cut.remaining(at: mix.previewPosition ?? v.cut.lo)
                    Text(verbatim: "· " + String(localized: "Vorhören") + " −" + Theme.time(rest) + " / " + Theme.time(v.cut.length)
                         + (v.cut.isCut ? " " + String(localized: "(Schnitt)") : ""))
                        .monospacedDigit()
                }
                .help("Vorhören: Restzeit bis zum Schnitt-Ende / Länge des Schnitts")
                Button("✕") { mix.stopPreview() }.buttonStyle(.plain).help("Vorhören beenden")
            }
        } else if mix.previewLoading != nil {
            HStack(spacing: 4.z) {
                Text(verbatim: "· " + String(localized: "Vorhören lädt …"))
                Button("✕") { mix.stopPreview() }.buttonStyle(.plain).help("Vorhören beenden")
            }
        }
    }
}

/// Titel-Zelle mit Vorschau dahinter (Einstellung „hinter dem Titel“, 25 % Deckkraft)
struct PreviewBehindTitle: ViewModifier {
    let mix: MixModel
    let track: Track

    func body(content: Content) -> some View {
        if mix.prefs.ui.previewMode == .behindTitle {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(TrackPreviewCell(mix: mix, track: track, fill: true).opacity(0.25))
        } else {
            content
        }
    }
}

/// gespeicherte Spaltenreihenfolge ohne „preview“: hinter „title“ einsetzen statt hinten anhängen
enum PreviewColumn {
    static func placed(_ data: Data) -> Data {
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var order = obj["columnOrder"] as? [Any] else { return data }
        let id = { (e: Any) in ((e as? [String: Any])?["base"] as? [String: Any]).flatMap { ($0["explicit"] as? [String: Any])?["_0"] as? String } }
        let ids = order.map(id)
        guard !ids.contains("preview") else { return data }
        let at = ids.firstIndex(of: "title").map { $0 + 1 } ?? order.count
        order.insert(["base": ["explicit": ["_0": "preview"]]], at: at)
        obj["columnOrder"] = order
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }
}

/// Rechtsklick im Baum: Vorschauen für eine Quelle berechnen
struct OverviewMenuButton: View {
    let tracks: () -> [Track]
    var body: some View {
        Button("Vorschauen berechnen") { Overviews.shared.enqueue(tracks()) }
    }
}

/// unsichtbar im Hauptfenster: Deck-Tracks übernehmen, Deck-Zustand für die Regel, Hintergrund-Liste, Grid-/Schnitt-Änderungen
struct OverviewHook: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    private struct Sig: Equatable { var keys: [String]; var grids: [String] }
    private struct Activity: Equatable { var playing: Bool; var loading: Bool }

    var body: some View {
        let decks = (0..<4).map { mix.deck($0) }
        let activity = Activity(playing: decks.contains { $0.playing }, loading: decks.contains { $0.loading })
        let sig = Sig(keys: decks.map { $0.loading ? "" : $0.track?.key ?? "" },
                      grids: decks.map { d in
                          "\(d.grid?.bpm ?? 0)|\(d.grid?.anchor ?? 0)|\(d.trim.start ?? -1)|\(d.trim.end ?? -1)|" + d.hotcues.values.map { "\($0.hotcue):\($0.startMs)" }.sorted().joined(separator: ",")
                      })
        // Selbsttest: Hintergrund nur mit MIX741_OVERVIEW_IDLE=1
        let fill = !Session.isSelfTest || ProcessInfo.processInfo.environment["MIX741_OVERVIEW_IDLE"] == "1" ? mix.prefs.ui.previewFill : .off
        let ov = Overviews.shared
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: activity, initial: true) {
                ov.setDecks(playing: activity.playing, loading: activity.loading)
                Analyses.shared.setDecks(playing: activity.playing, loading: activity.loading)
            }
            .onAppear {
                // eigene Analyse: Ergebnisse in die Library, Collection-Datei nach Einstellung (ein von Hand gesetztes Grid bleibt)
                let a = Analyses.shared
                a.library = store
                a.writeBack = { [mix] in mix.prefs.ui.writeCollection }
                a.bpmLow = { [mix] in mix.prefs.ui.analysisBpmLow }
                a.ripWithAnalysis = { [mix] in mix.prefs.ui.ripWithAnalysis }
            }
            .onChange(of: fill, initial: true) { ov.setMode(fill) }
            .onChange(of: sig.keys, initial: true) {
                for d in 0..<4 { if let t = mix.deck(d).track, let a = mix.audio(d) { ov.ingest(t, audio: a) } }
            }
            .onChange(of: sig.grids) { ov.bump() }
            .onChange(of: [store.revision, fill == .off ? 0 : 1, ov.loaded ? 1 : 0, ov.stopped ? 1 : 0], initial: true) {
                if ov.loaded, !store.tracks.isEmpty { ov.updateBackground(on: fill != .off, tracks: store.tracks) }
            }
            .accessibilityHidden(true)
    }
}

/// Statuszeile: Stapel (n/m) oder Hintergrund (mit Übersicht / alle), Tempo, reine Cloud-Dateien, ✕
struct OverviewStatus: View {
    @Environment(MixModel.self) private var mix

    static func state(_ g: OverviewPolicy.Gate) -> String? {
        switch g {
        case .full: nil
        case .throttled: String(localized: "gedrosselt")
        case .wait(.loading): String(localized: "pausiert (Deck lädt)")
        case .wait(.playing): String(localized: "pausiert (Deck spielt)")
        case .wait(.off): nil
        }
    }

    var body: some View {
        let o = Overviews.shared, p = o.progress
        let fill = mix.prefs.ui.previewFill
        if p.total > 0 {
            HStack(spacing: 4.z) {
                Text("· " + String(localized: "Vorschauen \(p.done)/\(p.total)"))
                if let s = Self.state(p.gate) { Text("· " + s).foregroundStyle(p.gate == .throttled ? Theme.muted : Theme.state) }
                Button("✕") { o.cancel() }.buttonStyle(.plain).help("Vorschauen berechnen abbrechen")
            }
        } else if fill != .off, !o.stopped, p.left > 0 {
            HStack(spacing: 4.z) {
                Text("· " + String(localized: "Vorschauen \(p.covered.formatted()) / \(p.collection.formatted())"))
                if let s = Self.state(p.gate) { Text("· " + s).foregroundStyle(p.gate == .throttled ? Theme.muted : Theme.state) }
                if p.onlineOnly > 0 {
                    Text("· " + String(localized: "\(p.onlineOnly.formatted()) nur online – Rechtsklick lädt"))
                        .help("Dateien nur in der Cloud: der Hintergrund lädt sie nicht herunter. Rechtsklick auf eine Quelle → Vorschauen berechnen liest sie trotzdem.")
                }
                Button("✕") { o.stop() }.buttonStyle(.plain).help("Hintergrund-Vorschauen bis zum nächsten Start anhalten")
            }
        } else if fill != .off, p.onlineOnly > 0 {
            Text("· " + String(localized: "\(p.onlineOnly.formatted()) nur online – Rechtsklick lädt"))
        }
    }
}

/// Einstellungen → Browser → Browser-Vorschau
struct PreviewSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Section("Browser-Vorschau") {
            Picker("Vorschau", selection: $mix.prefs.ui.previewMode) {
                ForEach(PreviewMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .settingsAnchor("browser.preview.mode")
            Picker("Vorschau-Farben", selection: $mix.prefs.ui.previewColors) {
                ForEach(PreviewColors.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .settingsAnchor("browser.preview.colors")
            Picker("Vorschauen im Hintergrund berechnen", selection: $mix.prefs.ui.previewFill) {
                ForEach(PreviewFill.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .settingsAnchor("browser.preview.fill")
            if mix.prefs.ui.previewMode == .fullRow {
                Picker("Schrift über dem Band", selection: $mix.prefs.ui.previewTextSize) {
                    ForEach([11.0, 12, 13, 14], id: \.self) { Text(verbatim: "\(Int($0)) pt").tag($0) }
                }
                .settingsAnchor("browser.preview.textsize")
                Toggle("Schrift halbfett", isOn: $mix.prefs.ui.previewTextBold)
                    .settingsAnchor("browser.preview.bold")
                Picker("Band", selection: $mix.prefs.ui.previewBandAlpha) {
                    Text("Voll").tag(1.0)
                    Text("Gedämpft").tag(0.75)
                    Text("Leicht").tag(0.5)
                }
                .settingsAnchor("browser.preview.band")
                Picker("Band-Breite", selection: $mix.prefs.ui.previewBandSpan) {
                    ForEach(PreviewBandSpan.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("browser.preview.bandspan")
            }
            Text("mini-übersicht je track: wellenform (spektrum: rot = bass, grün = mitten/synths, blau = höhen/drums, helle linie = großer energiesprung), phrasen, marker alle 16 / 32 takte, hotcues, start-cue. entsteht beim laden ins deck, per rechtsklick auf eine quelle -> vorschauen berechnen, oder im hintergrund: sichtbare zeilen zuerst, dann die neuesten tracks. immer: läuft auch beim spielen, gedrosselt (eine datei nach der anderen, halbe rechenzeit, niedrige priorität). nur wenn kein deck spielt: wartet, solange ein deck spielt. pausiert immer, solange ein deck lädt, und 4 s danach. dateien nur in der cloud lädt der hintergrund nicht herunter. gespeichert in ~/Library/Application Support/MINOS-741/overviews.")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}
