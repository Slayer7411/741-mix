import AppKit
import Foundation
import QuartzCore
import MixCore
import MixEngine
import MixMedia

/// EDIT-Modus mit Schnittliste: je Deck, solange EDIT an und ein Track geladen ist. Das Deck spielt die Liste – das
/// Original-Audio bleibt im Speicher, die Liste wird im Hintergrund in einen eigenen Puffer gerendert und ohne Laden
/// ins Deck getauscht (`MixController.swapAudio`). Ohne hörbare Änderung spielt das Deck das Original
@MainActor
final class EditSession {
    let key: String
    /// Audio des Originals (Rate des Decks)
    let source: TrackAudio
    /// Stand des Originals im Deck, bevor die Liste hörbar wurde (zurück beim Verlassen)
    var base: Track
    var baseGridEdited = false
    var baseTrim = TrackTrim()
    var baseCue = 0.0
    var baseActiveLoops: Set<Int> = []
    var baseGrid: BeatGrid?
    /// Ziel der letzten Bearbeitung
    var edl: EditList
    /// was das Deck gerade spielt
    var shown: EditList
    /// gerenderte Liste im Deck (nil = Original)
    var preview: TrackAudio?
    var seq = 0
    var rendering = false
    /// Position nach einer Bearbeitung, wenn die alte nicht mehr in der Liste liegt (Ausgabe-Zeit der neuen Liste)
    var landing: Double?
    /// Position nach dem nächsten Tausch, auch wenn die alte noch in der Liste liegt (A-B-A: Vorschau vor der Naht)
    var seekTo: Double?

    init(key: String, source: TrackAudio, deck s: DeckState) {
        self.key = key
        self.source = source
        base = s.track ?? Track(key: key, path: "")
        edl = EditList(duration: source.duration)
        shown = edl
        capture(s)
    }

    /// Stand des Originals übernehmen (nur solange das Deck das Original spielt)
    func capture(_ s: DeckState) {
        guard preview == nil, var t = s.track else { return }
        t.cues.removeAll { $0.hotcue >= 0 }
        t.cues.append(contentsOf: s.hotcues.values.sorted { $0.hotcue < $1.hotcue })
        if let g = s.grid {
            t.bpm = g.bpm
            if let i = t.cues.firstIndex(where: { $0.kind == .grid && $0.hotcue < 0 }) { t.cues[i].startMs = g.anchor * 1000 }
            else { t.cues.append(Cue(name: "Grid", kind: .grid, startMs: g.anchor * 1000, lengthMs: 0, hotcue: -1)) }
        }
        base = t
        baseGrid = s.grid
        baseGridEdited = s.gridEdited
        baseTrim = s.trim
        baseCue = s.cuePoint
        baseActiveLoops = s.activeLoops
    }

    var marks: WaveScene.EditMarks {
        let j = shown.joints
        let st = shown.starts
        let muted = shown.segments.indices.filter { shown.segments[$0].muted }.map { [st[$0], st[$0] + shown.segments[$0].length] }
        return WaveScene.EditMarks(joints: j, cuts: j.indices.map { shown.isCut(joint: $0) }, muted: muted,
                                   previewing: preview != nil, pending: rendering, segments: shown.segments.count)
    }
}

/// Bearbeitung auf dem markierten Bereich bzw. dem Stück unter dem Spielkopf
enum EditOp: String, CaseIterable {
    case remove, keep, duplicate, mute, left, right

    var label: String {
        switch self {
        case .remove: String(localized: "Bereich entfernen")
        case .keep: String(localized: "Nur Bereich behalten")
        case .duplicate: String(localized: "Bereich duplizieren")
        case .mute: String(localized: "Bereich stumm")
        case .left: String(localized: "Segment nach links")
        case .right: String(localized: "Segment nach rechts")
        }
    }
}

@MainActor
enum EditRender {
    static let queue = DispatchQueue(label: "minos741.edit", qos: .userInitiated)
    /// Selbsttest: Dauer des letzten Renderns (Hintergrund) und des Tauschs (Hauptthread), s
    static var lastSeconds = 0.0
    static var lastSwapSeconds = 0.0
}

extension MixModel {
    func editSession(_ d: Int) -> EditSession? { editSessions[d] }

    /// Deck spielt gerade eine gerenderte Schnittliste (auch per Instant Double übernommen)
    func isEditPreview(_ d: Int) -> Bool {
        guard !editSessions.isEmpty, let a = core.trackAudio(d) else { return false }
        return editSessions.values.contains { $0.preview === a }
    }

    /// Sitzung an den Deck-Stand anpassen: EDIT an + Track geladen -> Sitzung (gespeicherte Liste hörbar), anderer Track
    /// oder neu geladen -> neue Sitzung, EDIT aus -> zurück zum Original
    func syncEditSession(_ d: Int) {
        guard decks.indices.contains(d) else { return }
        let s = decks[d].state
        let cur = editSessions[d]
        if !decks[d].editing {
            if let cur { endEditSession(d, cur) }
            return
        }
        guard let t = s.track, !s.loading, let a = core.trackAudio(d) else {
            if cur != nil { editSessions[d] = nil; setEditMirror(d, nil) }
            return
        }
        if let cur, cur.key == t.key, cur.source === a || cur.preview === a { return }
        editSessions[d] = nil
        // eine gerenderte Liste (Instant Double von einem anderen Deck) ist kein Original
        guard !editSessions.values.contains(where: { $0.preview === a }) else { setEditMirror(d, nil); return }
        let n = EditSession(key: t.key, source: a, deck: s)
        if let saved = savedEditList(d, key: t.key), saved.fits(duration: a.duration) { n.edl = saved }
        editSessions[d] = n
        if !n.edl.sameAudio(as: n.shown) { renderEdit(d, n) } else { n.shown = n.edl }
        setEditMirror(d, n)
    }

    private func endEditSession(_ d: Int, _ s: EditSession) {
        editSessions[d] = nil
        s.seq += 1   // laufendes Rendern verwerfen
        if s.preview != nil, core.trackAudio(d) === s.preview {
            let pos = core.position(d)
            let src = s.shown.sourceTime(pos) ?? 0
            core.swapAudio(d, track: s.base, audio: s.source, position: src, cuePoint: s.baseCue, gridEdited: s.baseGridEdited,
                           trim: s.baseTrim, activeLoops: s.baseActiveLoops)
            pull()
        }
        setEditMirror(d, nil)
    }

    private func setEditMirror(_ d: Int, _ s: EditSession?) {
        let m = s?.marks
        if decks[d].edit != m { decks[d].edit = m }
    }

    // MARK: Bearbeiten

    /// Ziel: markierter Bereich, sonst das Stück unter dem Spielkopf
    private func editTarget(_ d: Int, _ s: EditSession) -> TrackRange? {
        if let r = range(d) { return r }
        return s.shown.segment(at: position(d)).flatMap { s.shown.range(of: $0) }
    }

    /// läuft das Rendern noch, wartet die nächste Bearbeitung (Bereiche gehören zur gespielten Liste)
    func readySession(_ d: Int) -> EditSession? {
        guard let s = editSessions[d] else {
            if deck(d).track != nil, !editing(d) { StatusCenter.post(.warning, String(localized: "Nur im EDIT-Modus"), key: "edit.\(d)") }
            return nil
        }
        guard !s.rendering else {
            StatusCenter.post(.info, String(localized: "Schnittliste wird noch gerechnet …"), key: "edit.\(d)")
            return nil
        }
        return s
    }

    func editAction(_ d: Int, _ op: EditOp) {
        guard let s = readySession(d), let r = editTarget(d, s) else { return }
        let rip = ripMark(d)
        var n = s.shown
        var newRange: TrackRange? = range(d)
        var landing: Double?
        let ok: Bool
        switch op {
        case .remove:
            ok = n.remove(r)
            newRange = nil
            landing = r.start
        case .keep:
            ok = n.keep(r)
            newRange = nil
            landing = 0
        case .duplicate:
            let c = n.duplicate(r)
            ok = c != nil
            newRange = c
        case .mute:
            ok = n.mute(r)
        case .left, .right:
            let m = n.move(r, by: op == .left ? -1 : 1)
            ok = m != nil
            if range(d) != nil { newRange = m }
            landing = m?.start
        }
        guard ok else {
            let why: String = switch op {
            case .remove, .keep: String(localized: "Ergebnis zu kurz (mindestens 1 s)")
            case .left, .right: String(localized: "Kein Segment daneben")
            default: String(localized: "Bereich zu kurz")
            }
            StatusCenter.post(.warning, why, key: "edit.\(d)")
            return
        }
        dropRipMark(d)   // Bereich gehört danach zur neuen Liste
        applyEdit(d, s, n, range: newRange, label: op.label, landing: landing)
        if op == .remove || op == .keep { ripRangeDone(rip) }
    }

    /// Schnittmarke bei t (Ausgabe-Zeit, schon gerastet)
    func editMark(_ d: Int, at t: Double) {
        guard let s = readySession(d) else { return }
        var n = s.shown
        guard n.split(at: t) else { return }
        applyEdit(d, s, n, range: range(d), label: String(localized: "Schnittmarke setzen"))
    }

    /// Marke am Spielkopf (nächster Beat, ⌥ = genau)
    func editMarkHere(_ d: Int, free: Bool = false) {
        let t = TrackRange.snap(position(d), grid: deck(d).grid, step: 1, free: free, duration: deck(d).duration)
        editMark(d, at: t)
    }

    /// Marke k entfernen (nur ohne Schnitt)
    func editRemoveMark(_ d: Int, _ k: Int) {
        guard let s = readySession(d) else { return }
        var n = s.shown
        guard n.removeMark(k) else {
            StatusCenter.post(.warning, String(localized: "Naht mit Schnitt: nur verschieben oder rückgängig"), key: "edit.\(d)")
            return
        }
        applyEdit(d, s, n, range: range(d), label: String(localized: "Schnittmarke entfernen"))
    }

    /// Naht k auf t verschieben (Ziehen = ein Schritt)
    func editMoveJoint(_ d: Int, _ k: Int, to t: Double) {
        guard let s = readySession(d) else { return }
        var n = s.shown
        guard n.moveJoint(k, to: t) else { setEditMirror(d, s); return }
        applyEdit(d, s, n, range: range(d), label: String(localized: "Schnittmarke verschieben"))
    }

    /// beim Ziehen einer Naht: nur die Anzeige
    func editShowJoint(_ d: Int, _ k: Int, at t: Double) {
        guard var m = decks[d].edit, m.joints.indices.contains(k) else { return }
        m.joints[k] = t
        decks[d].edit = m
    }

    /// Stück unter t als Bereich
    func editSelectSegment(_ d: Int, at t: Double) {
        guard let s = editSessions[d], let k = s.shown.segment(at: t), let r = s.shown.range(of: k) else { return }
        setRange(d, r)
    }

    /// ganze Liste verwerfen: Deck spielt das Original
    func editReset(_ d: Int) {
        guard let s = readySession(d), s.shown.segments.count > 1 || !s.shown.isPlain else { return }
        applyEdit(d, s, EditList(duration: s.source.duration), range: nil, label: String(localized: "Schnittliste verwerfen"),
                  landing: s.shown.sourceTime(position(d)))
    }

    func setEditSnap(_ v: EditSnap) { prefs.ui.editSnap = v }

    /// Liste übernehmen: Rückgängig, speichern, hörbar machen
    func applyEdit(_ d: Int, _ s: EditSession, _ n: EditList, range r: TrackRange?, label: String, landing: Double? = nil) {
        let before = (s.shown, range(d)), after = (n, r)
        UndoStack.shared.record(DeckUndoRecorder.label(label, deck: d), deck: d, before: before, after: after) { [weak self, weak s] b, a, undo in
            guard let self, let s, self.editSessions[d] === s else { return }
            let x = undo ? b : a
            self.setEdit(d, s, x.0, range: x.1, landing: nil)
        }
        setEdit(d, s, n, range: r, landing: landing)
    }

    private func setEdit(_ d: Int, _ s: EditSession, _ n: EditList, range r: TrackRange?, landing: Double?) {
        if s.preview == nil { s.capture(deck(d)) }
        s.edl = n
        s.landing = landing
        saveEditList(d, key: s.key, n.segments.count > 1 || !n.isPlain ? n : nil)
        if n.sameAudio(as: s.shown) {
            s.shown = n
            if decks[d].range != r { decks[d].range = r }
            setEditMirror(d, s)
            return
        }
        decks[d].range = nil   // Bereich gehört zur neuen Liste: erst nach dem Tausch
        pendingRange[d] = r
        renderEdit(d, s)
    }

    /// Liste hörbar machen: Original zurück oder im Hintergrund rendern und tauschen
    private func renderEdit(_ d: Int, _ s: EditSession) {
        s.seq += 1
        let seq = s.seq, edl = s.edl
        if edl.isPlain {
            s.rendering = false
            swapEdit(d, s, edl, audio: nil)
            return
        }
        s.rendering = true
        setEditMirror(d, s)
        let src = s.source
        let t0 = CACurrentMediaTime()
        EditRender.queue.async {
            let f = edl.frames(rate: src.sampleRate, sourceFrames: src.frames)
            let splice = AudioSplice(pieces: f.pieces, sourceFrames: src.frames, fade: AudioSplice.fadeFrames(sampleRate: src.sampleRate),
                                     muted: f.muted)
            let a = TrackAudio.rendered(splice, from: src)
            let secs = CACurrentMediaTime() - t0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.editSessions[d] === s, s.seq == seq else { return }
                    s.rendering = false
                    EditRender.lastSeconds = secs
                    self.swapEdit(d, s, edl, audio: a)
                }
            }
        }
    }

    private func swapEdit(_ d: Int, _ s: EditSession, _ edl: EditList, audio a: TrackAudio?) {
        let t0 = CACurrentMediaTime()
        defer { EditRender.lastSwapSeconds = CACurrentMediaTime() - t0 }
        // Position: alte Ausgabe-Zeit -> Quelle -> neue Ausgabe-Zeit; liegt sie nicht mehr in der Liste, an die Stelle der Bearbeitung
        let pos = position(d)
        let srcT = s.shown.sourceTime(pos)
        let at = max(0, s.seekTo ?? srcT.flatMap { edl.outputTime($0) } ?? s.landing ?? 0)
        let r = pendingRange[d] ?? nil
        pendingRange[d] = nil
        if let a {
            var t = TrackCut.track(from: s.base, key: s.base.key, path: s.base.path, grid: s.baseGrid,
                                   hotcues: s.base.hotcues, edl: edl, duration: a.duration)
            t.title = s.base.title + " [edit]"
            let cue = edl.outputTime(s.baseCue) ?? 0
            guard core.swapAudio(d, track: t, audio: a, position: min(at, a.duration), cuePoint: cue) else { return }
            s.preview = a
        } else if s.preview != nil {
            guard core.swapAudio(d, track: s.base, audio: s.source, position: min(at, s.source.duration), cuePoint: s.baseCue,
                                 gridEdited: s.baseGridEdited, trim: s.baseTrim, activeLoops: s.baseActiveLoops) else { return }
            s.preview = nil
        }
        s.shown = edl
        s.landing = nil
        s.seekTo = nil
        pull()
        if decks[d].range != r { decks[d].range = r }
        setEditMirror(d, s)
        prepareAudioChanged(d)
    }

    // MARK: Datei

    /// Liste als neue Datei rendern (`[cut]` neben dem Original, Metadaten, Grid, Cues), danach ggf. ins Deck laden
    /// `sheet`: Eingaben des EXPORT-Fensters (Format, Metadaten), nil = Einstellungen
    func editRenderFile(_ d: Int, load: Bool? = nil, sheet: ExportEdit? = nil) {
        guard let store = library, let s = readySession(d) else { return }
        guard !s.shown.isPlain else {
            StatusCenter.post(.warning, String(localized: "Schnittliste ohne Änderung"), key: "edit.\(d)")
            return
        }
        let dir: URL? = Session.isSelfTest ? CutJob.selfTestDirectory : nil
        CutJob.start(.init(deck: d, kind: .edit(s.shown), track: s.base, grid: s.baseGrid, hotcues: s.base.hotcues, audio: s.source,
                           load: load ?? prefs.ui.cutLoadsResult, directory: dir, sheet: sheet), mix: self, store: store)
    }

    /// Tool-Loop: n Beats ab dem aktiven Loop, sonst ab der Position (nächster Taktanfang), als eigene Datei
    func exportToolLoop(_ d: Int, beats: Int) {
        guard let store = library else { return }
        let s = deck(d)
        guard var t = s.track, !s.loading, let a = audio(d) else { return }
        guard let g = s.grid, g.bpm > 0 else {
            StatusCenter.post(.warning, String(localized: "Tool-Loop: Track ohne Grid"), key: "toolloop.\(d)")
            return
        }
        let l = engine.loop(d)
        guard let r = ToolLoop.range(beats: beats, grid: g, position: position(d), loopStart: l.active ? l.start : nil, duration: s.duration) else {
            StatusCenter.post(.warning, String(localized: "Tool-Loop: \(beats) Beats passen nicht mehr in den Track"), key: "toolloop.\(d)")
            return
        }
        let session = editSessions[d]
        let preview = session?.preview != nil && session?.preview === a
        if preview, let b = session?.base { t = b }   // Metadaten vom Original
        let folder = prefs.ui.toolLoopFolder
        let dir: URL? = Session.isSelfTest ? CutJob.selfTestDirectory : (folder.isEmpty ? nil : URL(fileURLWithPath: folder, isDirectory: true))
        CutJob.start(.init(deck: d, kind: .toolLoop(beats: beats, range: r, bpm: g.bpm, separators: prefs.ui.tagSeparators),
                           track: t, grid: g, hotcues: [], audio: a, direct: preview, load: false, directory: dir), mix: self, store: store)
    }
}
