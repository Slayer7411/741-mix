import AppKit
import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MixCore
import MixEngine
import MixMedia

/// Vorbereiten-Zustand eines Decks für die Werkzeugzeile: gilt für den Track `key` (anderer Track -> leer)
struct PrepMirror: Equatable {
    var key = ""
    /// gewünschter Gain (dB); bei NORM aus der gemessenen Spitze
    var gainDb = 0.0
    var norm = false
    /// Spitze (linear) dessen, was das Deck spielt (Original oder Schnittliste), nil = noch nicht gemessen
    var peak: Float?
    /// gemessenes Audio (Wechsel der Schnittliste -> neu messen)
    var audio: ObjectIdentifier?
    var measuring = false
    /// letzter Wunsch ging über den Headroom (auf 0 dBFS begrenzt)
    var limited = false

    /// Gain, wie er beim Rendern ungefähr wird (NORM: aus der Spitze des Decks)
    var shownGain: Double { norm ? max(0, peak.map { Amplify.normGain(peak: $0) } ?? 0) : gainDb }
    /// Abstand bis 0 dBFS nach dem Gain
    var headroomLeft: Double? { peak.map { Amplify.headroom(peak: $0) - shownGain } }
    var request: AmpRequest { norm ? .norm : .db(gainDb) }
}

// MARK: - Rendern (Hintergrund)

/// RENDER / SPLIT / JOIN im Hintergrund (Queue von CutJob): Schnittliste der Quelle, Gain, zweite Datei
enum PrepareRender {
    /// Hinweis statt Fehler (Statusleiste, gelb)
    struct Failure: Error {
        var text: String
    }

    static let analysis = DispatchQueue(label: "minos741.prepare", qos: .userInitiated)

    static func run(_ i: CutJob.Input, source: AudioCutWriter.Source, report: (Double) -> Bool) throws -> CutJob.Output {
        let src = URL(fileURLWithPath: i.track.path)
        let rate = source.sampleRate, chans = source.channels.count
        let fade = AudioSplice.fadeFrames(sampleRate: rate)
        let dir = i.directory ?? src.deletingLastPathComponent()
        let fm = FileManager.default
        let taken: (String) -> Bool = { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var format = AudioCutWriter.format(matching: src)
        let base = source.fromDeck ? 0 : 0.4
        func splice(_ e: EditList) -> AudioSplice {
            let f = e.frames(rate: rate, sourceFrames: source.frames)
            return AudioSplice(pieces: f.pieces, sourceFrames: source.frames, fade: fade, muted: f.muted)
        }
        func render(_ s: AudioSplice) -> AudioCutWriter.Render {
            { c, out, from, n in s.render(source.channels[c], into: out, from: from, count: n) }
        }
        func newTrack(_ url: URL, _ edl: EditList, duration: Double) -> Track {
            let vol = MusicFolder.volumeInfo(url.path)
            let key = MusicFolder.nmlKey(url.path, volume: vol.name, mount: vol.mount)
            return TrackCut.track(from: i.track, key: key, path: url.path, grid: i.grid, hotcues: i.hotcues, edl: edl, duration: duration)
        }

        switch i.kind {
        case let .prepare(edl, amp, allow):
            let s = splice(edl)
            guard Double(s.frames) >= rate * TrackTrim.minLength else { throw AudioCutWriter.CutError.empty }
            // Spitze der Ausgabe (Nähte eingerechnet), dann Gain: nur anheben, ohne Erlaubnis höchstens bis 0 dBFS
            let peak = AudioCutWriter.peak(frames: s.frames, channels: chans, render: render(s))
            let want = amp.gain(peak: peak)
            let lim = Amplify.limit(want, peak: peak, allowClipping: allow)
            let factor: Float = lim.db > 1e-9 ? (allow ? Float(Amplify.factor(db: lim.db)) : Amplify.safeFactor(lim.db, peak: peak)) : 1
            let db = factor == 1 ? 0 : Amplify.db(factor: Double(factor))
            guard let tag = PrepareName.renderTag(cut: !edl.isPlain, gain: db) else {
                throw Failure(text: String(localized: "Nichts zu rendern: Schnittliste ohne Änderung, AMP 0 dB"))
            }
            let url = dir.appendingPathComponent(PrepareName.fileName(src.lastPathComponent, tag: tag, ext: format.ext, taken: taken))
            try AudioCutWriter.write(frames: s.frames, channels: chans, sampleRate: rate, format: format, to: url, gain: factor,
                                     clamp: allow, render: render(s)) { report(base + (1 - base) * $0) }
            var t = newTrack(url, edl, duration: Double(s.frames) / rate)
            t.title = PrepareName.title(i.track.title, tag: tag)
            Amplify.loudness(&t, gain: db, peak: min(1, peak * factor))
            t.buildSearchText()
            CutJob.fileInfo(&t)
            var note: String?
            if lim.limited {
                note = String(format: String(localized: "Gain auf %@ dB begrenzt (Spitze %.1f dBFS, kein Clipping)"),
                              Amplify.label(db), Amplify.dbfs(peak: peak))
            } else if case .norm = amp {
                note = String(format: String(localized: "NORM %@ dB · Spitze %.1f dBFS"), Amplify.label(db), Amplify.dbfs(peak: peak * factor))
            }
            return CutJob.Output(tracks: [t], fromDeck: source.fromDeck, note: note, gain: db)

        case let .split(edl, at):
            guard let (p1, p2) = SplitPlan.parts(edl, at: at) else { throw AudioCutWriter.CutError.empty }
            var out: [Track] = []
            for (k, part) in [p1, p2].enumerated() {
                let s = splice(part)
                guard Double(s.frames) >= rate * TrackTrim.minLength else { throw AudioCutWriter.CutError.empty }
                let tag = SplitPlan.tag(k + 1)
                let url = dir.appendingPathComponent(PrepareName.fileName(src.lastPathComponent, tag: tag, ext: format.ext, taken: taken))
                let share = (1 - base) / 2, from = base + share * Double(k)
                do {
                    try AudioCutWriter.write(frames: s.frames, channels: chans, sampleRate: rate, format: format, to: url,
                                             render: render(s)) { report(from + share * $0) }
                } catch {
                    for t in out { try? fm.removeItem(atPath: t.path) }   // abgebrochen: kein halbes Paar
                    throw error
                }
                var t = newTrack(url, part, duration: Double(s.frames) / rate)
                t.title = PrepareName.title(i.track.title, tag: tag)
                t.buildSearchText()
                CutJob.fileInfo(&t)
                out.append(t)
            }
            return CutJob.Output(tracks: out, fromDeck: source.fromDeck)

        case let .join(edl, second, match):
            let a = splice(edl)
            guard a.frames > 0 else { throw AudioCutWriter.CutError.empty }
            let aTrack = TrackCut.track(from: i.track, key: "", path: "", grid: i.grid, hotcues: i.hotcues, edl: edl,
                                        duration: Double(a.frames) / rate)
            let b0 = try AudioCutWriter.source(url: URL(fileURLWithPath: second.path), deck: nil) { report(0.4 + 0.2 * $0) }
            let gridB = BeatGrid(track: second)
            let plan = JoinPlan.plan(durationA: Double(a.frames) / rate, gridA: BeatGrid(track: aTrack),
                                     durationB: Double(b0.frames) / b0.sampleRate, gridB: gridB, matchTempo: match)
            let b = try AudioCutWriter.converted(b0, rate: rate, channels: chans, speed: plan.speed)
            let join = AudioJoin(aFrames: a.frames, joint: Int((plan.joint * rate).rounded()),
                                 bStart: Int((plan.startB / plan.speed * rate).rounded()), bFrames: b.frames, fade: fade)
            guard join.frames > 0 else { throw AudioCutWriter.CutError.empty }
            if !format.float { format.bitDepth = max(format.bitDepth, b0.bitDepth) }
            if format.container == .alac { format = .alac(format.bitDepth) }
            let url = dir.appendingPathComponent(PrepareName.joinName(src.lastPathComponent, (second.path as NSString).lastPathComponent,
                                                                      ext: format.ext, taken: taken))
            try AudioCutWriter.write(frames: join.frames, channels: chans, sampleRate: rate, format: format, to: url, render: { c, out, from, n in
                join.render(a: { o, f, k in a.render(source.channels[c], into: o, from: f, count: k) }, b: b.channels[c],
                            into: out, from: from, count: n)
            }) { report(0.6 + 0.4 * $0) }
            let vol = MusicFolder.volumeInfo(url.path)
            let key = MusicFolder.nmlKey(url.path, volume: vol.name, mount: vol.mount)
            var t = plan.track(a: aTrack, b: second, key: key, path: url.path, cuesA: aTrack.cues, cuesB: second.cues,
                               duration: Double(join.frames) / rate)
            CutJob.fileInfo(&t)
            var note: String?
            if plan.tempoMismatch, let ga = BeatGrid(track: aTrack), let gb = gridB {
                note = String(format: String(localized: "Tempo verschieden (%.2f / %.2f BPM): Raster der zweiten läuft gegen das Grid"), ga.bpm, gb.bpm)
            } else if abs(plan.speed - 1) > 1e-9 {
                note = String(format: String(localized: "Tempo der zweiten angeglichen (%+.2f %%)"), (plan.speed - 1) * 100)
            } else if gridB == nil {
                note = String(localized: "zweite Datei ohne Grid: ab ihrem Anfang angehängt")
            }
            return CutJob.Output(tracks: [t], fromDeck: source.fromDeck, note: note)

        default:
            throw AudioCutWriter.CutError.format
        }
    }
}

// MARK: - Aktionen

/// Decks, die die Werkzeugzeile in den EDIT-Modus gebracht hat (verschwindet sie, geht EDIT wieder aus)
@MainActor private var prepOwnedEdit: Set<Int> = []

extension MixModel {
    /// Vorbereiten-Zustand des geladenen Tracks
    func prepState(_ d: Int) -> PrepMirror {
        let p = decks[d].prep
        return p.key == decks[d].trackKey ? p : PrepMirror(key: decks[d].trackKey)
    }

    private func setPrep(_ d: Int, _ f: (inout PrepMirror) -> Void) {
        var p = prepState(d)
        f(&p)
        if decks[d].prep != p { decks[d].prep = p }
    }

    /// Werkzeugzeile erscheint: Deck in den EDIT-Modus (Ziehen markiert, Klick setzt Marken), Spitze messen
    func prepareRowAppeared(_ d: Int) {
        guard decks.indices.contains(d) else { return }
        if !editing(d) {
            prepOwnedEdit.insert(d)
            setEditing(d, true)
        }
        if prepState(d).peak == nil { prepareAnalyse(d) }
    }

    /// Werkzeugzeile weg: EDIT aus, wenn sie ihn eingeschaltet hat
    func prepareRowDisappeared(_ d: Int) {
        guard prepOwnedEdit.remove(d) != nil, decks.indices.contains(d) else { return }
        setEditing(d, false)
    }

    /// Sitzung für eine Aktion der Zeile (schaltet EDIT ein, falls aus)
    private func prepSession(_ d: Int) -> EditSession? {
        if !editing(d), deck(d).track != nil {
            prepOwnedEdit.insert(d)
            setEditing(d, true)
        }
        return readySession(d)
    }

    // MARK: Amp

    /// Spitze dessen messen, was das Deck spielt (Hintergrund); `then` danach auf dem Hauptthread
    func prepareAnalyse(_ d: Int, then: (@MainActor () -> Void)? = nil) {
        guard let a = audio(d), !deck(d).loading else { return }
        let key = decks[d].trackKey, id = ObjectIdentifier(a)
        setPrep(d) { $0.measuring = true }
        PrepareRender.analysis.async {
            let peak = AudioCutWriter.peak([a.left, a.right], frames: a.frames)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.decks[d].trackKey == key else { return }
                    self.setPrep(d) { p in
                        p.peak = peak
                        p.audio = id
                        p.measuring = false
                        let l = Amplify.limit(p.gainDb, peak: peak, allowClipping: self.prefs.ui.prepAllowClipping)
                        if !p.norm, l.limited {
                            p.gainDb = l.db
                            p.limited = true
                        }
                    }
                    then?()
                }
            }
        }
    }

    /// Deck spielt anderes Audio (Schnittliste getauscht): gemessene Spitze neu
    func prepareAudioChanged(_ d: Int) {
        let p = prepState(d)
        guard p.peak != nil, let a = audio(d), p.audio != ObjectIdentifier(a) else { return }
        prepareAnalyse(d)
    }

    /// AMP +x dB (nur anheben; über den Headroom: Warnung, begrenzt auf 0 dBFS, außer Clipping ist erlaubt)
    func prepareAmp(_ d: Int, add db: Double) {
        guard deck(d).track != nil else { return }
        guard let peak = prepState(d).peak else { prepareAnalyse(d) { [weak self] in self?.prepareAmp(d, add: db) }; return }
        let p = prepState(d)
        let lim = Amplify.limit(p.shownGain + db, peak: peak, allowClipping: prefs.ui.prepAllowClipping)
        setPrep(d) {
            $0.norm = false
            $0.gainDb = lim.db
            $0.limited = lim.limited
        }
        if lim.limited {
            StatusCenter.post(.warning, String(format: String(localized: "AMP: nur %@ dB ohne Clipping (Spitze %.1f dBFS)"),
                                               Amplify.label(lim.db), Amplify.dbfs(peak: peak)), key: "prep.\(d)")
        }
    }

    /// NORM: Spitze genau auf −0.3 dBFS (beim Rendern aus der Spitze der Ausgabe)
    func prepareNorm(_ d: Int) {
        guard deck(d).track != nil else { return }
        guard let peak = prepState(d).peak else { prepareAnalyse(d) { [weak self] in self?.prepareNorm(d) }; return }
        setPrep(d) { $0.norm = true; $0.limited = false; $0.gainDb = max(0, Amplify.normGain(peak: peak)) }
        if Amplify.normGain(peak: peak) <= 0 {
            StatusCenter.post(.info, String(format: String(localized: "NORM: Spitze schon bei %.1f dBFS, nichts anzuheben"),
                                            Amplify.dbfs(peak: peak)), key: "prep.\(d)")
        }
    }

    func prepareAmpReset(_ d: Int) { setPrep(d) { $0.norm = false; $0.gainDb = 0; $0.limited = false } }

    // MARK: Schnitt

    /// B IN / B OUT: Bereichsanfang bzw. -ende an die Position, auf das Raster der Zeile
    func prepareMark(_ d: Int, end: Bool) {
        let s = deck(d)
        guard s.track != nil, s.duration > 0 else { return }
        _ = prepSession(d)
        let step = prefs.ui.editSnap.beats
        let t = TrackRange.snap(position(d), grid: s.grid, step: step, free: false, duration: s.duration)
        let len = s.grid.map { step * $0.beat } ?? 4
        let r: TrackRange
        if let old = range(d) {
            r = end ? TrackRange(old.start, t) : TrackRange(t, old.end)
        } else {
            r = end ? TrackRange(max(0, t - len), t) : TrackRange(t, min(s.duration, t + len))
        }
        setRange(d, r.length > 1e-6 ? r : nil)
    }

    /// Bereich bzw. Stück unter dem Spielkopf aus der Schnittliste entfernen / behalten (EDIT REMOVE / KEEP)
    func prepareEdit(_ d: Int, _ op: EditOp) {
        guard prepSession(d) != nil else { return }
        editAction(d, op)
    }

    /// A-B-A: markierter Bereich (oder das Stück zwischen zwei Marken unter dem Spielkopf) = B, heraus; A und A
    /// schließen am Grid mit 2-ms-Crossfade an. Vorschau: das Deck steht 2 Takte vor der Naht
    func prepareABA(_ d: Int) {
        guard let s = prepSession(d) else { return }
        let e = s.shown, dur = e.duration, grid = deck(d).grid
        var r: TrackRange
        if let x = range(d) {
            r = x
        } else if let k = e.segment(at: position(d)), k > 0, k < e.segments.count - 1, let x = e.range(of: k) {
            r = x
        } else {
            StatusCenter.post(.warning, String(localized: "A-B-A: B markieren (ziehen, B IN / B OUT oder zwischen zwei Marken)"), key: "prep.\(d)")
            return
        }
        r = TrackRange(TrackRange.snap(r.start, grid: grid, free: false, duration: dur), TrackRange.snap(r.end, grid: grid, free: false, duration: dur))
        guard r.start >= EditList.minSegment, r.end <= dur - EditList.minSegment else {
            StatusCenter.post(.warning, String(localized: "A-B-A: vor und hinter B muss Audio bleiben (sonst REMOVE / KEEP)"), key: "prep.\(d)")
            return
        }
        var n = e
        guard r.length >= EditList.minSegment, n.remove(r) else {
            StatusCenter.post(.warning, String(localized: "Ergebnis zu kurz (mindestens 1 s)"), key: "prep.\(d)")
            return
        }
        let pre = grid.map { 2 * BeatGrid.beatsPerBar * $0.beat } ?? 4
        s.seekTo = max(0, r.start - pre)
        applyEdit(d, s, n, range: nil, label: String(localized: "A-B-A: B heraus"), landing: r.start)
        let beats = grid.map { " · " + r.beatsText(grid: $0) + " Beats" } ?? ""
        StatusCenter.post(.ok, String(format: String(localized: "A-B-A: B heraus%@ · Vorschau ab 2 Takten vor der Naht"), beats), key: "prep.\(d)")
    }

    // MARK: Datei

    /// Grid, das beim Rendern gilt: wurde es während der Vorschau verstellt, zurück in Zeit der Quelle (Stück, in dem
    /// der Anker liegt) – Grid setzen geht so auch nach dem Schneiden
    private func prepBaseGrid(_ d: Int, _ s: EditSession) {
        guard s.preview != nil, audio(d) === s.preview, let g = deck(d).grid else { return }
        let shown = s.baseGrid.map { s.shown.grid($0) }
        guard g != shown, let a = s.shown.sourceTime(g.anchor) else { return }
        let n = BeatGrid(anchor: a, bpm: g.bpm)
        s.baseGrid = n
        s.baseGridEdited = true
        s.base.bpm = n.bpm
        if let i = s.base.cues.firstIndex(where: { $0.kind == .grid && $0.hotcue < 0 }) { s.base.cues[i].startMs = n.anchor * 1000 }
        else { s.base.cues.append(Cue(name: "Grid", kind: .grid, startMs: n.anchor * 1000, lengthMs: 0, hotcue: -1)) }
    }

    private var prepDirectory: URL? { Session.isSelfTest ? CutJob.selfTestDirectory : nil }

    /// RENDER: Schnittliste + AMP in eine neue Datei (ein Durchgang), ggf. ins Deck (Lade-Schutz), unter CUTS
    func prepareRender(_ d: Int, load: Bool? = nil) {
        guard let store = library, let s = prepSession(d) else { return }
        let p = prepState(d)
        guard !s.shown.isPlain || !p.request.isNone else {
            StatusCenter.post(.warning, String(localized: "Nichts zu rendern: Schnittliste ohne Änderung, AMP 0 dB"), key: "prep.\(d)")
            return
        }
        prepBaseGrid(d, s)
        CutJob.start(.init(deck: d, kind: .prepare(s.shown, amp: p.request, allowClipping: prefs.ui.prepAllowClipping),
                           track: s.base, grid: s.baseGrid, hotcues: s.base.hotcues, audio: s.source,
                           load: load ?? prefs.ui.cutLoadsResult, directory: prepDirectory), mix: self, store: store)
    }

    /// SPLIT: am Bereichsanfang, sonst am Taktanfang nächst der Position, in zwei Dateien `[part 1]`, `[part 2]`
    func prepareSplit(_ d: Int) {
        guard let store = library, let s = prepSession(d) else { return }
        guard let t = SplitPlan.point(range: range(d), position: position(d), grid: deck(d).grid, duration: s.shown.duration) else {
            StatusCenter.post(.warning, String(localized: "SPLIT: Marke zu nah am Rand (mindestens 1 s je Teil)"), key: "prep.\(d)")
            return
        }
        prepBaseGrid(d, s)
        CutJob.start(.init(deck: d, kind: .split(s.shown, at: t), track: s.base, grid: s.baseGrid, hotcues: s.base.hotcues,
                           audio: s.source, load: false, directory: prepDirectory), mix: self, store: store)
    }

    /// JOIN: `second` ans Ende dessen, was das Deck spielt (am Grid, Tempo angeglichen bis ±0,5 %)
    func prepareJoin(_ d: Int, with second: Track) {
        guard let store = library, let s = prepSession(d) else { return }
        let b = edits.edit(for: second.key)?.apply(to: second) ?? second
        guard !b.path.isEmpty, FileManager.default.fileExists(atPath: b.path) else {
            StatusCenter.post(.warning, String(localized: "JOIN: Datei fehlt"), detail: b.path, key: "prep.\(d)")
            return
        }
        prepBaseGrid(d, s)
        CutJob.start(.init(deck: d, kind: .join(s.shown, second: b, matchTempo: prefs.ui.prepJoinMatchTempo), track: s.base,
                           grid: s.baseGrid, hotcues: s.base.hotcues, audio: s.source, load: prefs.ui.cutLoadsResult,
                           directory: prepDirectory), mix: self, store: store)
    }

    /// JOIN-Knopf: gewählter Track im Browser (nicht der im Deck), sonst Datei wählen
    func prepareJoinAsking(_ d: Int, browser: BrowserState, store: LibraryStore) {
        if let t = browser.selectedTrack(), t.key != deck(d).track?.key, editSession(d)?.base.key != t.key {
            prepareJoin(d, with: t)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = String(localized: "Zweite Datei für JOIN wählen (oder Track aus dem Browser auf JOIN ziehen)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        let t = store.tracks.first { $0.path == path } ?? store.cuts.first { $0.path == path } ?? {
            var t = Track(key: path, path: path)
            t.title = url.deletingPathExtension().lastPathComponent
            return t
        }()
        prepareJoin(d, with: t)
    }
}

// MARK: - Werkzeugzeile

/// Vorbereiten: eine Zeile für Tracks vorbereiten – Play, Grid (BPM, TAP, SET, Nudge, Anker), Schnitt am Raster
/// (B IN / OUT, REMOVE, KEEP, A-B-A), AMP (Gain, Headroom, Analyse, +1 +3 +6, NORM), JOIN (Track darauf ziehen oder
/// Klick), SPLIT, RENDER. Schmale Decks: Grid, Schnitt und Amp als Menüs
struct PrepareRow: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    struct Model: Equatable {
        var playing = false, bpm: Double?, edited = false, snap = EditSnap.bar, previewing = false, pending = false
        var prep = PrepMirror(), hasTrack = false
    }

    var body: some View {
        let s = mix.deck(d), e = mix.decks[d].edit
        Content(d: d, m: Model(playing: s.playing, bpm: s.grid?.bpm, edited: s.gridEdited, snap: mix.prefs.ui.editSnap,
                               previewing: e?.previewing ?? false, pending: e?.pending ?? false, prep: mix.prepState(d),
                               hasTrack: s.track != nil)).equatable()
            .onAppear { mix.prepareRowAppeared(d) }
            .onDisappear { mix.prepareRowDisappeared(d) }
    }

    struct Content: View, Equatable {
        @Environment(MixModel.self) private var mix
        @Environment(LibraryStore.self) private var store
        @Environment(BrowserState.self) private var browser
        let d: Int
        let m: Model
        @State private var joinTarget = false
        static func == (a: Self, b: Self) -> Bool { a.d == b.d && a.m == b.m }

        var body: some View {
            HStack(spacing: 3.z) {
                FirstFit {
                    row(compact: false)
                    row(compact: true)
                }
                Spacer(minLength: 0)
            }
        }

        private func sep() -> some View { Divider().frame(height: 14.z) }

        private func label(_ t: String, on: Bool = false) -> some View {
            Text(LocalizedStringKey(t)).font(Theme.label(9.z, .bold)).foregroundStyle(on ? Theme.state : Theme.muted).fixedSize()
        }

        private func row(compact: Bool) -> some View {
            HStack(spacing: 3.z) {
                DeckButton(title: m.playing ? "❚❚" : "▶", active: m.playing, color: Theme.state, width: 30) { mix.togglePlay(d) }.stable()
                sep()
                label("GRID", on: m.edited)
                if compact { gridMenu } else { gridButtons }
                sep()
                label("CUT", on: m.previewing)
                snapButton
                if !compact {
                    DeckButton(title: "B IN") { mix.prepareMark(d, end: false) }.stable()
                        .help("Anfang von B an die Position (auf dem Raster)")
                    DeckButton(title: "B OUT") { mix.prepareMark(d, end: true) }.stable()
                        .help("Ende von B an die Position (auf dem Raster)")
                }
                DeckButton(title: "REMOVE") { mix.prepareEdit(d, .remove) }.stable()
                    .help("Bereich (sonst Segment am Spielkopf) aus der Schnittliste entfernen")
                if !compact {
                    DeckButton(title: "KEEP") { mix.prepareEdit(d, .keep) }.stable().help("Nur Bereich behalten")
                }
                DeckButton(title: "A-B-A", active: true, color: Theme.state) { mix.prepareABA(d) }.stable()
                    .help("Markierten Bereich B herausnehmen, A und A am Grid zusammenführen (2 ms Crossfade), Vorschau im Deck")
                if compact { cutMenu }
                sep()
                label("AMP", on: m.prep.shownGain > 0)
                ampReadout(compact: compact)
                if compact { ampMenu } else { ampButtons }
                sep()
                DeckButton(title: "JOIN", active: joinTarget, color: Theme.state) { mix.prepareJoinAsking(d, browser: browser, store: store) }
                    .help("Zweite Datei ans Ende am Grid: Track aus dem Browser hierher ziehen, Klick = gewählter Track im Browser oder Datei wählen")
                    .onDrop(of: [.text], isTargeted: $joinTarget) { providers in
                        TrackDrag.keys(providers) { keys in
                            guard let k = keys.first, let t = store.track(k) else { return }
                            mix.prepareJoin(d, with: t)
                        }
                    }
                DeckButton(title: "SPLIT") { mix.prepareSplit(d) }.stable()
                    .help("In zwei Dateien teilen: am Bereichsanfang, sonst am Taktanfang nächst der Position")
                sep()
                DeckButton(title: "RENDER", active: m.previewing || m.prep.shownGain > 0, color: Theme.state) { mix.prepareRender(d) }.stable()
                    .help("Schnittliste + AMP als neue Datei rendern (Original bleibt)")
                    .uiTestFrame("\(d).render", on: !compact)
                RipDeckButton(d: d)
            }
            .opacity(m.pending ? 0.6 : 1)
            .disabled(!m.hasTrack)
            .fixedSize()
        }

        @ViewBuilder private var gridButtons: some View {
            DeckButton(title: "BPM −") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) - 0.01) }.stable()
            Text(m.bpm.map { String(format: "%.3f", $0) } ?? "—").font(Theme.mono(10.z)).frame(width: 52.z)
            DeckButton(title: "+") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) + 0.01) }.stable()
            DeckButton(title: "TAP") { mix.tapGrid(d) }.stable().help("Auf die Beats tippen: ab 4 Taps BPM des Grids")
            DeckButton(title: "SET") { mix.setGridAnchorHere(d) }.stable().help("Beat 1 an die aktuelle Position")
            DeckButton(title: "◂") { mix.shiftGrid(d, ms: -1) }.stable().help("Grid 1 ms früher")
            DeckButton(title: "▸") { mix.shiftGrid(d, ms: 1) }.stable().help("Grid 1 ms später")
            DeckButton(title: "◂1") { mix.shiftGridBeats(d, -1) }.stable().help("Grid-Anker 1 Beat früher (Raster bleibt)")
            DeckButton(title: "1▸") { mix.shiftGridBeats(d, 1) }.stable().help("Grid-Anker 1 Beat später (Raster bleibt)")
        }

        private var gridMenu: some View {
            Menu {
                Button("BPM −0.01") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) - 0.01) }
                Button("BPM +0.01") { mix.setGridBPM(d, (mix.deck(d).grid?.bpm ?? 0) + 0.01) }
                Button("TAP") { mix.tapGrid(d) }
                Button("SET (Beat 1 hier)") { mix.setGridAnchorHere(d) }
                Divider()
                Button("Grid 1 ms früher") { mix.shiftGrid(d, ms: -1) }
                Button("Grid 1 ms später") { mix.shiftGrid(d, ms: 1) }
                Button("Grid-Anker 1 Beat früher (Raster bleibt)") { mix.shiftGridBeats(d, -1) }
                Button("Grid-Anker 1 Beat später (Raster bleibt)") { mix.shiftGridBeats(d, 1) }
            } label: {
                Text(verbatim: (m.bpm.map { String(format: "%.2f", $0) } ?? "—") + " ▾").font(Theme.mono(10.z))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }

        private var cutMenu: some View {
            Menu {
                Button("B IN (Anfang an die Position)") { mix.prepareMark(d, end: false) }
                Button("B OUT (Ende an die Position)") { mix.prepareMark(d, end: true) }
                Button("Nur Bereich behalten") { mix.prepareEdit(d, .keep) }
                Button("Bereich aufheben") { mix.clearRange(d) }
            } label: { Text(verbatim: "▾").font(Theme.label(10.z, .bold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }

        @ViewBuilder private var ampButtons: some View {
            DeckButton(title: "ANALYSE", active: m.prep.measuring, color: Theme.secondary) { mix.prepareAnalyse(d) }.stable()
                .help("Spitze messen (was das Deck spielt)")
            ForEach(Amplify.steps, id: \.self) { s in
                DeckButton(title: "+\(Int(s))") { mix.prepareAmp(d, add: s) }.stable()
                    .help("Lautstärke um \(Int(s)) dB anheben (nur Gain, kein Limiter)")
                    .uiTestFrame("\(d).amp.\(Int(s))")
            }
            DeckButton(title: "NORM", active: m.prep.norm, color: Theme.state) { mix.prepareNorm(d) }.stable()
                .help("Spitze genau auf −0.3 dBFS")
            DeckButton(title: "0") { mix.prepareAmpReset(d) }.stable().help("AMP aus (0 dB)")
        }

        private var ampMenu: some View {
            Menu {
                Button("ANALYSE (Spitze messen)") { mix.prepareAnalyse(d) }
                ForEach(Amplify.steps, id: \.self) { s in Button("+\(Int(s)) dB") { mix.prepareAmp(d, add: s) } }
                Button("NORM (−0.3 dBFS)") { mix.prepareNorm(d) }
                Button("0 dB") { mix.prepareAmpReset(d) }
            } label: { Text(verbatim: "▾").font(Theme.label(10.z, .bold)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }

        /// Gain und Headroom: „+3.0 dB · +1.2 dB bis Vollaussteuerung“
        private func ampReadout(compact: Bool) -> some View {
            let p = m.prep
            let gain = (p.norm ? "NORM " : "") + Amplify.label(p.shownGain) + " dB"
            let room: String = p.measuring ? "…" : p.headroomLeft.map { h in
                h.isFinite ? String(format: String(localized: compact ? "%@ frei" : "%@ dB bis Vollaussteuerung"), Amplify.label(h)) : String(localized: "Stille")
            } ?? String(localized: "nicht gemessen")
            return HStack(spacing: 4.z) {
                Text(verbatim: gain).font(Theme.mono(10.z)).foregroundStyle(p.limited ? Theme.state : Theme.bone)
                Text(verbatim: room).font(Theme.mono(9.z)).foregroundStyle(Theme.muted)
            }
            .fixedSize()
            .help(p.peak.map { String(format: String(localized: "Spitze %.1f dBFS · nur Gain: die Samples werden mit dem Faktor multipliziert"), Amplify.dbfs(peak: $0)) }
                  ?? String(localized: "ANALYSE misst die Spitze"))
        }

        /// Raster beim Markieren: Klick = nächstes, ⌥-Klick = voriges
        private var snapButton: some View {
            DeckButton(title: m.snap.label) {
                mix.setEditSnap(NSEvent.modifierFlags.contains(.option) ? m.snap.previous : m.snap.next)
            }
            .help("Raster beim Markieren: Klick = nächstes, ⌥-Klick = voriges, ⌥ beim Ziehen = frei")
        }
    }
}

/// UI-Selbsttest: unsichtbare AppKit-Ansicht hinter einzelnen Tasten (nur während des UI-Tests), der Test findet sie
/// in der Fenster-Hierarchie und klickt auf ihre Mitte
@MainActor
enum UITestFrames {
    static var on = false

    final class Marker: NSView {
        var id = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    struct Tag: NSViewRepresentable {
        let id: String
        func makeNSView(context: Context) -> Marker { let v = Marker(); v.id = id; return v }
        func updateNSView(_ v: Marker, context: Context) { v.id = id }
    }
}

extension View {
    @ViewBuilder func uiTestFrame(_ id: String, on: Bool = true) -> some View {
        if UITestFrames.on, on { background(UITestFrames.Tag(id: id)) } else { self }
    }
}
