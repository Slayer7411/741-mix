import AppKit
import os
import SwiftUI
import MixCore
import MixEngine

/// Browser-Vorschau: wo die Mini-Übersicht (Wellenform + Grid + Cues) steht
enum PreviewMode: String, CaseIterable, Codable, Identifiable {
    case column = "Eigene Spalte", behindTitle = "Hinter dem Titel", off = "Aus"
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

    private init() {
        let store = store, jobs = jobs
        store.onChange = { key in
            jobs.stored(key)
            DispatchQueue.main.async { MainActor.assumeIsolated { Overviews.shared.bump() } }
        }
        jobs.store = store
        jobs.onProgress = { p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let o = Overviews.shared
                    if o.progress != p { o.progress = p }
                }
            }
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
        jobs.enqueue(tracks.filter { !$0.path.isEmpty }.map { .init(key: $0.key, path: $0.path, explicit: true) })
    }

    /// sichtbare Zeile ohne Übersicht -> vor den Hintergrund
    func want(_ t: Track) {
        guard !stopped, !t.loose, t.fileExists else { return }
        jobs.want(key: t.key, path: t.path)
    }

    func cancel() { jobs.cancel() }

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
    struct Mark: Hashable, Sendable { var t: Double; var r: UInt8, g: UInt8, b: UInt8 }
    var key: String
    var path: String
    /// Generation der gespeicherten Übersicht (0 = keine)
    var gen: Int
    var duration: Double
    var bpm: Double
    var anchor: Double
    var phraseBeats: Int
    var cues: [Mark]
    var start: Mark?
    var palette: WaveformPalette
    var style: WaveformStyle
    var colors: PreviewColors

    /// Track mit den eigenen Grid-/Cue-Änderungen (wie beim Laden ins Deck)
    @MainActor init(_ track: Track, mix: MixModel) {
        let t = mix.edits.edit(for: track.key)?.apply(to: track) ?? track
        self.init(t, ui: mix.prefs.ui, controller: mix.prefs.controller, info: Overviews.shared.store.info(t.key))
    }

    /// ohne Modell (Selbsttest-Bilder): Übersicht direkt übergeben
    init(_ t: Track, ui: UIPrefs, controller: ControllerPrefs, overview: TrackOverview) {
        self.init(t, ui: ui, controller: controller, info: (gen: 1, duration: overview.duration))
    }

    private init(_ t: Track, ui: UIPrefs, controller c: ControllerPrefs, info: (gen: Int, duration: Double)?) {
        key = t.key
        path = t.path
        gen = info?.gen ?? 0
        duration = info?.duration ?? t.duration
        let grid = BeatGrid(track: t)
        let tempo = grid?.bpm ?? 0
        bpm = tempo
        anchor = grid?.anchor ?? 0
        phraseBeats = max(4, ui.phraseBeats)
        palette = ui.waveformPalette
        style = ui.waveformStyle
        colors = ui.previewColors
        let startMs = Theme.startCueMs(t)
        let mark = { (ms: Double, p: PadColor) in Mark(t: ms / 1000, r: p.rgb.r, g: p.rgb.g, b: p.rgb.b) }
        cues = t.hotcues.map { mark($0.startMs, c.color(for: $0, startMs: startMs, bpm: tempo)) }
        start = startMs.map { mark($0, c.colorStartCue) }
    }
}

enum PreviewRenderer {
    /// Bildgröße in Pixeln (2×): 200 × 17 pt, die Zelle streckt es auf ihre Breite
    static let width = 400, height = 34
    static let heightPt: CGFloat = 17

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    static let bone = rgb(230 / 255, 225 / 255, 218 / 255, 1)
    static let lila = rgb(150 / 255, 70 / 255, 210 / 255, 1)
    static let magenta = rgb(0.88, 0.22, 0.78, 1)
    static let void = rgb(10 / 255, 9 / 255, 8 / 255, 0.9)
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

    /// Mini-Übersicht: Phrasen-Bänder, 3-Band-Wellenform (gedämpft), Marker alle 16/32 Takte, Hotcues, Start-Cue
    static func render(_ s: PreviewSpec, overview: TrackOverview?) -> CGImage? {
        let w = width, h = height
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
            let colors = RenderedWaveform.Colors.of(s.palette)
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
                case .threeBand:
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
        // Hotcues: kurze farbige Striche oben; Start-Cue: Dreieck oben
        // dunkler Rand, damit weiße Cues auf heller Wellenform sichtbar bleiben
        ctx.setFillColor(void)
        ctx.fill(s.cues.map { CGRect(x: $0.t * pps - 2.5, y: H * 0.4, width: 5, height: H * 0.6) })
        for c in s.cues {
            ctx.setFillColor(rgb(CGFloat(c.r) / 127, CGFloat(c.g) / 127, CGFloat(c.b) / 127, 1))
            ctx.fill(CGRect(x: c.t * pps - 1.5, y: H * 0.4, width: 3, height: H * 0.6))
        }
        if let st = s.start {
            let x = st.t * pps
            ctx.setFillColor(rgb(CGFloat(st.r) / 127, CGFloat(st.g) / 127, CGFloat(st.b) / 127, 1))
            ctx.move(to: CGPoint(x: x - 5, y: H)); ctx.addLine(to: CGPoint(x: x + 5, y: H)); ctx.addLine(to: CGPoint(x: x, y: H - 8))
            ctx.closePath(); ctx.fillPath()
        }
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
        }
        .frame(maxWidth: .infinity)
        .frame(height: fill ? nil : PreviewRenderer.heightPt)
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

/// unsichtbar im Hauptfenster: Deck-Tracks übernehmen, Deck-Zustand für die Regel, Hintergrund-Liste, Grid-Änderungen
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
                          "\(d.grid?.bpm ?? 0)|\(d.grid?.anchor ?? 0)|" + d.hotcues.values.map { "\($0.hotcue):\($0.startMs)" }.sorted().joined(separator: ",")
                      })
        // Selbsttest: Hintergrund nur mit MIX741_OVERVIEW_IDLE=1
        let fill = !Session.isSelfTest || ProcessInfo.processInfo.environment["MIX741_OVERVIEW_IDLE"] == "1" ? mix.prefs.ui.previewFill : .off
        let ov = Overviews.shared
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: activity, initial: true) { ov.setDecks(playing: activity.playing, loading: activity.loading) }
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

    private static func state(_ g: OverviewPolicy.Gate) -> String? {
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
            HStack(spacing: 4) {
                Text("· " + String(localized: "Vorschauen \(p.done)/\(p.total)"))
                if let s = Self.state(p.gate) { Text("· " + s).foregroundStyle(p.gate == .throttled ? Theme.muted : Theme.state) }
                Button("✕") { o.cancel() }.buttonStyle(.plain).help("Vorschauen berechnen abbrechen")
            }
        } else if fill != .off, !o.stopped, p.left > 0 {
            HStack(spacing: 4) {
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

/// Einstellungen → Anzeige → Browser-Vorschau
struct PreviewSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Section("Browser-Vorschau") {
            Picker("Vorschau", selection: $mix.prefs.ui.previewMode) {
                ForEach(PreviewMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("Vorschau-Farben", selection: $mix.prefs.ui.previewColors) {
                ForEach(PreviewColors.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Picker("Vorschauen im Hintergrund berechnen", selection: $mix.prefs.ui.previewFill) {
                ForEach(PreviewFill.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            Text("mini-übersicht je track: wellenform (spektrum: rot = bass, grün = mitten/synths, blau = höhen/drums, helle linie = großer energiesprung), phrasen, marker alle 16 / 32 takte, hotcues, start-cue. entsteht beim laden ins deck, per rechtsklick auf eine quelle -> vorschauen berechnen, oder im hintergrund: sichtbare zeilen zuerst, dann die neuesten tracks. immer: läuft auch beim spielen, gedrosselt (eine datei nach der anderen, halbe rechenzeit, niedrige priorität). nur wenn kein deck spielt: wartet, solange ein deck spielt. pausiert immer, solange ein deck lädt, und 4 s danach. dateien nur in der cloud lädt der hintergrund nicht herunter. gespeichert in ~/Library/Application Support/MINOS-741/overviews.")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}
