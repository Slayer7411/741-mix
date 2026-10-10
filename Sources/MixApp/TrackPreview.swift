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

/// Übersichten aller Tracks: Speicher, Nachrechnen (Deck, Stapel, Leerlauf) und ein gedrosselter Zähler, an dem
/// die sichtbaren Vorschau-Zellen hängen. Regel: der Stapel rechnet nur, solange kein Deck spielt oder lädt.
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
    /// Stapel-Fortschritt (Rechtsklick → Vorschauen berechnen)
    private(set) var done = 0
    private(set) var total = 0
    /// Leerlauf: noch offen
    private(set) var idleLeft = 0
    private(set) var paused = false
    @ObservationIgnored private var tickPending = false

    private init() {
        let store = store
        store.onChange = { _ in DispatchQueue.main.async { MainActor.assumeIsolated { Overviews.shared.bump() } } }
        jobs.store = store
        jobs.onProgress = { p in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let o = Overviews.shared
                    if o.done != p.done { o.done = p.done }
                    if o.total != p.total { o.total = p.total }
                    if o.idleLeft != p.idleLeft { o.idleLeft = p.idleLeft }
                    if o.paused != p.paused { o.paused = p.paused }
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

    func cancel() { jobs.cancel() }

    /// Leerlauf-Liste neu: Collection-Tracks ohne Übersicht, neueste zuerst (Filter im Hintergrund)
    func updateIdle(on: Bool, tracks: [Track]) {
        guard on else { jobs.setIdle([]); return }
        let store = store, jobs = jobs
        DispatchQueue.global(qos: .utility).async {
            let list = tracks.filter { !$0.loose && $0.fileExists && !$0.path.isEmpty && !store.contains($0.key) }
                .sorted { ($0.importDate ?? .distantPast) > ($1.importDate ?? .distantPast) }
            jobs.setIdle(list.map { .init(key: $0.key, path: $0.path, explicit: false) })
        }
    }

    func setBusy(_ busy: Bool) { jobs.busy.withLock { $0 = busy } }
}

/// Warteschlange + Arbeiter (eigene Threads, QoS utility, höchstens 2; Leerlauf nur 1). Pause, solange ein Deck
/// spielt oder lädt – auch mitten in einer Datei (zwischen zwei Lese-Blöcken).
final class OverviewJobs: @unchecked Sendable {
    struct Job { let key: String; let path: String; let explicit: Bool }
    struct Progress { var done = 0, total = 0, idleLeft = 0, paused = false }

    var store: OverviewStore?
    var onProgress: (@Sendable (Progress) -> Void)?
    let busy = OSAllocatedUnfairLock(initialState: false)
    /// Selbsttest: Arbeiter erst nach dem Laden starten; `maxWorkers` für Messungen
    var maxWorkers = 2

    private let lock = NSLock()
    private var explicit: [Job] = []
    private var queued: Set<String> = []
    private var idle: [Job] = []
    private var workers = 0
    private var started = false
    private var cancelGen = 0
    private var failed: Set<String> = []
    private var progress = Progress()

    func start() {
        lock.lock(); started = true; lock.unlock()
        spawn()
    }

    func enqueue(_ jobs: [Job]) {
        lock.lock()
        for j in jobs where !queued.contains(j.key) {
            explicit.append(j)
            queued.insert(j.key)
            progress.total += 1
        }
        lock.unlock()
        report()
        spawn()
    }

    func setIdle(_ jobs: [Job]) {
        lock.lock()
        idle = jobs.reversed()   // von hinten abarbeiten
        progress.idleLeft = idle.count
        lock.unlock()
        report()
        spawn()
    }

    func cancel() {
        lock.lock()
        cancelGen += 1
        explicit.removeAll(); queued.removeAll(); idle.removeAll()
        progress = Progress()
        lock.unlock()
        report()
    }

    /// wartet (z. B. Messung), bis Stapel und Leerlauf leer sind und kein Arbeiter mehr läuft
    var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return workers == 0 && explicit.isEmpty && idle.isEmpty }

    private func wanted() -> Int { !explicit.isEmpty ? maxWorkers : (!idle.isEmpty ? 1 : 0) }

    private func spawn() {
        lock.lock()
        guard started else { lock.unlock(); return }
        var n = 0
        while workers < wanted() { workers += 1; n += 1 }
        lock.unlock()
        for _ in 0..<n {
            let t = Thread { [self] in work() }
            t.qualityOfService = .utility
            t.name = "minos741.overview"
            t.start()
        }
    }

    private func report() {
        lock.lock(); let p = progress; lock.unlock()
        onProgress?(p)
    }

    private func setPaused(_ on: Bool) {
        lock.lock()
        let changed = progress.paused != on
        progress.paused = on
        lock.unlock()
        if changed { report() }
    }

    private struct Cancelled: Error {}

    /// solange ein Deck spielt/lädt: warten; abgebrochen -> werfen
    private func waitWhileBusy(gen: Int) throws {
        var waited = false
        while busy.withLock({ $0 }) {
            if !waited { waited = true; setPaused(true) }
            lock.lock(); let g = cancelGen; lock.unlock()
            if g != gen { throw Cancelled() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if waited { setPaused(false) }
        lock.lock(); let g = cancelGen; lock.unlock()
        if g != gen { throw Cancelled() }
    }

    private func work() {
        while true {
            lock.lock()
            // zu viele Arbeiter für die Lage (nur noch Leerlauf) -> einer hört auf
            if workers > wanted() || (explicit.isEmpty && idle.isEmpty) {
                workers -= 1
                if explicit.isEmpty, progress.done >= progress.total { progress.done = 0; progress.total = 0 }
                lock.unlock()
                report()
                return
            }
            let job = explicit.isEmpty ? idle.removeLast() : explicit.removeFirst()
            if !job.explicit { progress.idleLeft = idle.count }
            let gen = cancelGen
            let skip = failed.contains(job.key)
            lock.unlock()
            if !skip { process(job, gen: gen) }
            lock.lock()
            if job.explicit, gen == cancelGen { progress.done += 1; queued.remove(job.key) }
            lock.unlock()
            report()
        }
    }

    private func process(_ job: Job, gen: Int) {
        guard let store else { return }
        do {
            try waitWhileBusy(gen: gen)
            if store.isValid(job.key, path: job.path) { return }
            // Leerlauf: Dateien, die nur in der Cloud liegen, nicht herunterladen lassen
            if !job.explicit, Self.isDataless(job.path) { return }
            guard let stamp = OverviewStore.Stamp.of(path: job.path) else { return }
            let ov = try OverviewAnalyzer.analyze(url: URL(fileURLWithPath: job.path)) { try waitWhileBusy(gen: gen) }
            store.put(job.key, path: job.path, overview: ov, stamp: stamp)
        } catch is Cancelled {
        } catch {
            lock.lock(); failed.insert(job.key); lock.unlock()
        }
    }

    /// Datei nur als Platzhalter vorhanden (Cloud-Ordner, Inhalt nicht geladen)
    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_flags & 0x4000_0000) != 0   // SF_DATALESS
    }
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

    /// Track mit den eigenen Grid-/Cue-Änderungen (wie beim Laden ins Deck)
    @MainActor init(_ track: Track, mix: MixModel) {
        let t = mix.edits.edit(for: track.key)?.apply(to: track) ?? track
        let info = Overviews.shared.store.info(t.key)
        key = t.key
        path = t.path
        gen = info?.gen ?? 0
        duration = info?.duration ?? t.duration
        let grid = BeatGrid(track: t)
        let tempo = grid?.bpm ?? 0
        bpm = tempo
        anchor = grid?.anchor ?? 0
        let ui = mix.prefs.ui, c = mix.prefs.controller
        phraseBeats = max(4, ui.phraseBeats)
        palette = ui.waveformPalette
        style = ui.waveformStyle
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
                ctx.setFillColor(lila.copy(alpha: 0.16)!); ctx.fill(bands)
                ctx.setFillColor(bone.copy(alpha: 0.28)!); ctx.fill(m16)
                ctx.setFillColor(magenta.copy(alpha: 0.7)!); ctx.fill(m32)
            }
        }
        // Wellenform (gedämpft, Farben aus den Einstellungen)
        if let o = overview, o.count > 0 {
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

/// unsichtbar im Hauptfenster: Deck-Tracks übernehmen, Pause-Regel, Leerlauf-Liste, Grid-Änderungen
struct OverviewHook: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    private struct Sig: Equatable { var keys: [String]; var grids: [String] }

    var body: some View {
        let decks = (0..<4).map { mix.deck($0) }
        let busy = decks.contains { $0.playing || $0.loading }
        let sig = Sig(keys: decks.map { $0.loading ? "" : $0.track?.key ?? "" },
                      grids: decks.map { d in
                          "\(d.grid?.bpm ?? 0)|\(d.grid?.anchor ?? 0)|" + d.hotcues.values.map { "\($0.hotcue):\($0.startMs)" }.sorted().joined(separator: ",")
                      })
        let idleOn = mix.prefs.ui.previewBackground && (!Session.isSelfTest || ProcessInfo.processInfo.environment["MIX741_OVERVIEW_IDLE"] == "1")
        let ov = Overviews.shared
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: busy, initial: true) { ov.setBusy(busy) }
            .onChange(of: sig.keys, initial: true) {
                for d in 0..<4 { if let t = mix.deck(d).track, let a = mix.audio(d) { ov.ingest(t, audio: a) } }
            }
            .onChange(of: sig.grids) { ov.bump() }
            .onChange(of: [store.revision, idleOn ? 1 : 0, ov.loaded ? 1 : 0], initial: true) {
                if ov.loaded, !store.tracks.isEmpty { ov.updateIdle(on: idleOn, tracks: store.tracks) }
            }
            .accessibilityHidden(true)
    }
}

/// Statuszeile: Fortschritt des Stapels, Pause, Abbrechen
struct OverviewStatus: View {
    var body: some View {
        let o = Overviews.shared
        if o.total > 0 {
            HStack(spacing: 4) {
                Text("· " + String(localized: "Vorschauen \(o.done)/\(o.total)"))
                if o.paused { Text("pausiert (Deck spielt)").foregroundStyle(Theme.state) }
                Button("✕") { o.cancel() }.buttonStyle(.plain).help("Vorschauen berechnen abbrechen")
            }
        } else if o.idleLeft > 0, !o.paused {
            Text("· " + String(localized: "Vorschauen: \(o.idleLeft) offen"))
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
            Toggle("Vorschauen im Hintergrund berechnen (nur wenn kein Deck spielt)", isOn: $mix.prefs.ui.previewBackground)
            Text("mini-übersicht je track: wellenform, phrasen, marker alle 16 / 32 takte, hotcues, start-cue. entsteht beim laden ins deck, per rechtsklick auf eine quelle -> vorschauen berechnen, oder im hintergrund. pausiert, solange ein deck spielt oder lädt. gespeichert in ~/Library/Application Support/MINOS-741/overviews.")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
        }
    }
}
