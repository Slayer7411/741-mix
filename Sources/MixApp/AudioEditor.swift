import AppKit
import MixCore
import MixEngine
import MixMedia

// Editor im AUDIO-EDIT-Modus: Wellenform von Deck A (Ausgabe der Schnittliste), Auswahl und Cursor in Ausgabe-Zeit,
// Ansicht, Marken (Quellzeit, eigene Datei) und Bearbeiten über die Schnittliste (Rückgängig, Render wie bisher).
// Nur Befehle hier; Zeichnen und Eingabe in AudioEditEditor.swift.
extension AudioEditMode {
    /// Audio des Editors (Deck A: gerenderte Liste oder Original)
    var audio: TrackAudio? { mix?.audio(Self.deck) }
    var duration: Double { audio?.duration ?? 0 }
    var rate: Double { audio?.sampleRate ?? 44_100 }
    var playhead: Double { mix?.position(Self.deck) ?? 0 }
    var playing: Bool { mix?.deck(Self.deck).playing ?? false }
    /// Schnittliste, wie Deck A sie spielt (nil ohne EDIT-Sitzung)
    var shown: EditList? { mix?.editSession(Self.deck)?.shown }
    /// Track im Editor = der auf Deck A geladene (auch von Hand geladen, nicht nur aus der Arbeitsliste)
    var editTrack: Track? { mix?.deck(Self.deck).track }

    /// Editor bereit: EDIT-Sitzung da und nicht mitten im Rendern (sonst Hinweis in der Statuszeile)
    private func session() -> EditSession? { mix?.readySession(Self.deck) }

    /// Taste im Editor: true = erledigt (sonst läuft die Aktion wie bisher)
    @discardableResult
    func perform(_ a: ShortcutID) -> Bool {
        switch a {
        case .play: playToggle()
        case .loop: playFromCursor()
        case .zoomIn: zoomKey(AudioEditView.zoomStep)
        case .zoomOut: zoomKey(1 / AudioEditView.zoomStep)
        case .zoomReset: fitView()
        case .audioEditZoomSelection: zoomToSelection()
        case .audioEditSelectAll: selectAll()
        case .audioEditDelete: delete()
        case .audioEditCrop: crop()
        case .audioEditSilence: silence()
        case .audioEditReverse: reverse()
        case .audioEditCut: cut()
        case .audioEditCopy: copy()
        case .audioEditPaste: paste()
        case .audioEditMarker: addMarker(range: false)
        case .audioEditSnap: snapToggle()
        case .audioEditBack: back(by: 5)
        case .audioEditStop: stop()
        default: return false
        }
        return true
    }

    // MARK: Transport

    /// Leertaste: stoppt, sonst ab dem Cursor spielen
    func playToggle() {
        guard let mix, mix.deck(Self.deck).track != nil else { return }
        if playing { mix.togglePlay(Self.deck) } else { playFromCursor() }
    }

    /// L: ab dem Cursor spielen (läuft es schon, unverändert)
    func playFromCursor() {
        guard let mix, mix.deck(Self.deck).track != nil, !playing else { return }
        mix.core.seek(Self.deck, seconds: cursor)
        mix.togglePlay(Self.deck)
    }

    /// K: stoppen, der Cursor bleibt
    func stop() {
        guard let mix, playing else { return }
        mix.togglePlay(Self.deck)
        setCursor(mix.position(Self.deck))
    }

    /// J: Sprung zurück (Cursor und Spielkopf)
    func back(by s: Double) {
        guard let mix, mix.deck(Self.deck).track != nil else { return }
        setCursor(max(0, playhead - s))
    }

    /// Cursor setzen; steht das Deck, springt es dorthin (ohne Rückgängig-Eintrag)
    func setCursor(_ t: Double) {
        cursor = min(max(0, t), duration)
        if let mix, !playing, mix.deck(Self.deck).track != nil { mix.core.seek(Self.deck, seconds: cursor) }
    }

    // MARK: Auswahl

    /// Auswahl auf ganze Samples begrenzt; leer oder ohne Länge = keine Auswahl
    func setSelection(_ r: TrackRange?) {
        guard let r, duration > 0 else { selection = nil; return }
        let a = AudioEditView.aligned(min(max(0, r.start), duration), rate: rate)
        let b = AudioEditView.aligned(min(max(0, r.end), duration), rate: rate)
        selection = b - a >= 1 / rate - 1e-9 ? TrackRange(a, b) : nil
    }

    func selectAll() {
        guard duration > 0 else { return }
        setSelection(TrackRange(0, duration))
    }

    /// Zeit, wie der Editor sie setzt: Raster (SNAP an, Beat des Grids) oder Sample-genau
    func snapped(_ t: Double) -> Double {
        guard duration > 0 else { return 0 }
        let step = mix?.prefs.ui.audioEditSnapBeats ?? 1
        let v = snap ? TrackRange.snap(t, grid: mix?.deck(Self.deck).grid, step: step, free: false, duration: duration) : t
        return AudioEditView.aligned(min(max(0, v), duration), rate: rate)
    }

    func snapToggle() {
        snap.toggle()
        StatusCenter.post(.info, snap ? String(localized: "Raster an") : String(localized: "Raster aus"), key: "audioedit.snap")
    }

    /// Stück unter t als Auswahl (Doppelklick)
    func segmentRange(at t: Double) -> TrackRange? {
        guard let l = shown, let k = l.segment(at: t) else { return nil }
        return l.range(of: k)
    }

    // MARK: Ansicht

    /// Zeit unter dem Punkt x und Punkt einer Zeit
    func time(atX x: Double) -> Double { AudioEditView.time(x: x, start: viewStart, secPerPoint: secPerPoint) }
    func x(atTime t: Double) -> Double { AudioEditView.x(t, start: viewStart, secPerPoint: secPerPoint) }

    /// Breite der Wellenform gemeldet: beim ersten Mal ganze Datei, sonst Ansicht in den Grenzen halten
    func layoutChanged(width: Double) {
        guard width > 0 else { return }
        viewWidth = width
        if secPerPoint <= 0 { fitView(); return }
        setView(secPerPoint, viewStart)
    }

    private func setView(_ s: Double, _ start: Double) {
        guard duration > 0, viewWidth > 0 else { return }
        let v = AudioEditView.clamp(secPerPoint: s, start: start, width: viewWidth, duration: duration, rate: rate)
        secPerPoint = v.secPerPoint
        viewStart = v.start
    }

    /// Zoom um t (liegt bei Punkt x); Faktor > 1 = hinein
    func zoom(by f: Double, at t: Double, x xp: Double) {
        guard duration > 0, viewWidth > 0, secPerPoint > 0 else { return }
        let v = AudioEditView.zoom(secPerPoint: secPerPoint, start: viewStart, by: f, at: t, x: xp, width: viewWidth,
                                   duration: duration, rate: rate)
        secPerPoint = v.secPerPoint
        viewStart = v.start
    }

    /// Taste: um den Cursor, wenn er sichtbar ist, sonst um die Mitte
    func zoomKey(_ f: Double) {
        let xc = x(atTime: cursor)
        let inView = xc >= 0 && xc <= viewWidth
        zoom(by: f, at: inView ? cursor : time(atX: viewWidth / 2), x: inView ? xc : viewWidth / 2)
    }

    /// ganze Datei in der Breite
    func fitView() {
        guard duration > 0, viewWidth > 0 else { return }
        let v = AudioEditView.fit(duration: duration, width: viewWidth, rate: rate)
        secPerPoint = v.secPerPoint
        viewStart = v.start
    }

    /// Auswahl füllt die Breite (ohne Auswahl: ganze Datei)
    func zoomToSelection() {
        guard let r = selection, duration > 0, viewWidth > 0 else { return fitView() }
        let v = AudioEditView.fit(r, width: viewWidth, duration: duration, rate: rate)
        secPerPoint = v.secPerPoint
        viewStart = v.start
    }

    /// horizontal scrollen (Sekunden)
    func scroll(by s: Double) { setView(secPerPoint, viewStart + s) }

    /// Spielkopf im Bild halten, solange er läuft
    func followPlayhead() {
        guard playing, secPerPoint > 0, viewWidth > 0 else { return }
        let ph = playhead, span = viewWidth * secPerPoint
        if ph < viewStart || ph > viewStart + span * 0.92 { setView(secPerPoint, ph - span * 0.1) }
    }

    // MARK: Bearbeiten (Schnittliste)

    /// Schnittliste ändern: Rückgängig und Render wie bisher; danach Cursor und Auswahl in der neuen Liste
    private func change(_ label: String, _ n: EditList, selection s: TrackRange?, cursor c: Double) {
        guard let mix, let sess = session() else { return }
        let at = min(max(0, c), n.duration)
        mix.applyEdit(Self.deck, sess, n, range: nil, label: label, landing: at)
        cursor = at
        selection = s.flatMap { r in r.end <= n.duration + 1e-9 && r.length > 0 ? r : nil }
    }

    /// Auswahl gibt es nicht: Hinweis
    private func needSelection() -> TrackRange? {
        guard let r = selection else {
            StatusCenter.post(.info, String(localized: "Erst einen Bereich markieren"), key: "audioedit.edit")
            return nil
        }
        return r
    }

    /// Auswahl löschen (Rest rückt zusammen)
    func delete() {
        guard let r = needSelection(), var n = shown else { return }
        guard n.remove(r) else { return warn(String(localized: "Ergebnis zu kurz (mindestens 1 s)")) }
        change(String(localized: "Auswahl löschen"), n, selection: nil, cursor: r.start)
    }

    /// nur die Auswahl behalten (Rest weg)
    func crop() {
        guard let r = needSelection(), var n = shown else { return }
        guard n.keep(r) else { return warn(String(localized: "Ergebnis zu kurz (mindestens 1 s)")) }
        change(String(localized: "Nur Auswahl behalten"), n, selection: nil, cursor: 0)
    }

    /// Auswahl durch Stille gleicher Länge ersetzen, oder Stille am Cursor einfügen (Länge im Dialog)
    func silence() {
        guard let n0 = shown else { return }
        let sel = selection
        guard let pick = askSilence(selection: sel) else { return }
        let len = pick.length, replace = pick.replace
        var n = n0
        if replace, let r = sel {
            guard n.replaceWithSilence(r) else { return warn(String(localized: "Bereich zu kurz")) }
            change(String(localized: "Stille über Auswahl"), n, selection: r, cursor: r.start)
        } else {
            let a = cursor
            guard n.insertSilence(at: a, length: len) else { return warn(String(localized: "Länge zu kurz")) }
            change(String(localized: "Stille einfügen"), n, selection: TrackRange(a, a + len), cursor: a)
        }
    }

    /// Auswahl rückwärts abspielen (Stücke umkehren, Nähte blenden wie sonst)
    func reverse() {
        guard let r = needSelection(), var n = shown else { return }
        guard let out = n.reverse(r) else { return warn(String(localized: "Bereich zu kurz")) }
        change(String(localized: "Auswahl rückwärts"), n, selection: out, cursor: out.start)
    }

    /// Auswahl in die Zwischenablage (nur Stücke dieses Tracks)
    @discardableResult
    func copy() -> Bool {
        guard let r = needSelection(), let key = editTrack?.key, let segs = shown?.copy(r) else { return false }
        clip = AudioEditClip(key: key, segments: segs)
        StatusCenter.post(.info, String(localized: "Kopiert: \(AudioEditView.clock(r.length))"), key: "audioedit.edit")
        return true
    }

    /// ausschneiden: kopieren, dann löschen
    func cut() {
        guard copy(), let r = selection, var n = shown else { return }
        guard n.remove(r) else { return warn(String(localized: "Ergebnis zu kurz (mindestens 1 s)")) }
        change(String(localized: "Auswahl ausschneiden"), n, selection: nil, cursor: r.start)
    }

    /// Zwischenablage am Cursor einfügen (Rest rückt nach hinten)
    func paste() {
        guard let c = clip, c.key == editTrack?.key, var n = shown else {
            return warn(String(localized: "Zwischenablage leer oder aus einem anderen Track"))
        }
        guard let out = n.paste(c.segments, at: cursor) else { return }
        change(String(localized: "Einfügen"), n, selection: out, cursor: out.end)
    }

    private func warn(_ s: String) { StatusCenter.post(.warning, s, key: "audioedit.edit") }

    /// Dialog Stille: mit Auswahl ersetzen (Dauer bleibt) oder am Cursor einfügen; Länge in m:ss.mmm oder Sekunden
    private func askSilence(selection sel: TrackRange?) -> (length: Double, replace: Bool)? {
        let a = NSAlert()
        a.messageText = String(localized: "Stille einfügen")
        a.informativeText = sel == nil
            ? String(localized: "Länge der Stille, eingefügt am Cursor.")
            : String(localized: "Mit Auswahl: Stille über den Bereich (Dauer bleibt). Oder die Länge unten am Cursor einfügen.")
        let field = NSTextField(string: AudioEditView.clock(sel?.length ?? 1))
        field.frame = NSRect(x: 0, y: 0, width: 220, height: 24)
        a.accessoryView = field
        if sel != nil { a.addButton(withTitle: String(localized: "Auswahl ersetzen")) }
        a.addButton(withTitle: sel == nil ? String(localized: "Einfügen") : String(localized: "Am Cursor einfügen"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        let hasSel = sel != nil
        let first = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let pick = a.runModal().rawValue - first
        if hasSel, pick == 0 { return (sel?.length ?? 0, true) }
        guard pick == (hasSel ? 1 : 0) else { return nil }
        guard let len = AudioEditView.parse(field.stringValue), len > 0 else {
            warn(String(localized: "Länge nicht lesbar"))
            return nil
        }
        return (AudioEditView.aligned(len, rate: rate), false)
    }

    // MARK: Marken

    /// Marken des Tracks neu lesen (Trackwechsel, Eintritt)
    func reloadMarks() {
        marks = (editTrack.map { markStore.markers($0.key) } ?? []).sorted { $0.start < $1.start }
    }

    private func saveMarks() {
        guard let key = editTrack?.key else { return }
        markStore.set(marks, for: key)
    }

    /// Marke am Cursor (Quellzeit) oder Bereich aus der Auswahl; Name Standard „Marke n“ / „Bereich n“, per Doppelklick ändern
    func addMarker(range: Bool) {
        guard let n = shown, editTrack != nil else { return }
        if range {
            guard let r = selection, let a = n.sourceTime(r.start), let b = n.sourceTime(r.end) else {
                return warn(String(localized: "Erst einen Bereich markieren"))
            }
            let count = marks.filter { $0.end != nil }.count + 1
            marks.append(AudioMarker(name: String(localized: "Bereich \(count)"), start: min(a, b), end: max(a, b)))
        } else {
            guard let s = n.sourceTime(cursor) else { return }
            let count = marks.filter { $0.end == nil }.count + 1
            marks.append(AudioMarker(name: String(localized: "Marke \(count)"), start: s))
        }
        marks.sort { $0.start < $1.start }
        saveMarks()
    }

    /// Name ändern (Dialog); leer = unverändert
    func renameMarker(_ id: UUID) {
        guard let i = marks.firstIndex(where: { $0.id == id }) else { return }
        let a = NSAlert()
        a.messageText = String(localized: "Name der Marke")
        let field = NSTextField(string: marks[i].name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "OK"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        marks[i].name = name
        saveMarks()
    }

    func deleteMarker(_ id: UUID) {
        marks.removeAll { $0.id == id }
        saveMarks()
    }

    /// Zur Marke springen (Cursor und Deck); liegt sie nicht mehr in der Liste, unverändert
    func jumpMarker(_ id: UUID) {
        guard let m = marks.first(where: { $0.id == id }), let t = shown?.outputTime(m.start) else { return }
        setCursor(t)
    }

    /// Ausgabe-Zeit einer Marke (nil = Stelle liegt nicht mehr in der Liste)
    func outputTime(_ m: AudioMarker) -> Double? { shown?.outputTime(m.start) }
}
