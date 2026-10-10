import SwiftUI
import AppKit
import MixCore

// Metadaten im Browser bearbeiten – Verhalten wie im Bearbeiten-Dialog der Collection-Software:
// Inline (zweiter Klick auf die gewählte Zeile oder Return, Tab = nächste Spalte, Esc = abbrechen),
// Bearbeiten-Fenster (⌘E / Rechtsklick) mit PREV/NEXT, Mehrfachauswahl mit „auf alle anwenden“-Kästchen.

/// gerade bearbeitete Zelle; `serial` unterscheidet zwei Bearbeitungen derselben Zelle
struct InlineEdit: Equatable {
    var key: String
    var field: TrackField
    var serial: Int
}

/// Inline-Bearbeitung einer Tabelle: erkennt den zweiten Klick auf die gewählte Zeile (über das NSTableView
/// darunter, ohne die Auswahl der Tabelle zu stören), startet das Feld, behandelt Tab/Return/Esc und übernimmt.
@MainActor
final class InlineEditController {
    weak var finder: TableViewFinder.FinderView?
    weak var model: BrowserPaneModel?
    weak var store: LibraryStore?
    var rows: () -> [Track] = { [] }
    var writeBack: () -> Bool = { false }
    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var pending: DispatchWorkItem?
    private var lastField: TrackField?
    private var serial = 0

    /// Spalten-ID der Tabelle -> Feld (Spalten ohne Eintrag sind nicht bearbeitbar: Datei, Zeit, Bitrate, Import, Plays …)
    static let columnFields: [String: TrackField] = [
        "artist": .artist, "title": .title, "remixer": .remixer, "producer": .producer, "release": .album,
        "trackno": .trackNumber, "bpm": .bpm, "keytext": .keyText, "rating": .rating, "comment": .comment,
        "comment2": .comment2, "label": .label, "catalog": .catalogNo, "genre": .genre, "releasedate": .releaseDate, "mix": .mix,
    ]

    var table: NSTableView? { finder?.table() }

    func install() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            if self?.chipDown(e) == true { return nil }   // Tag-Chip: Tabelle bekommt den Klick nicht
            self?.mouseDown(e)
            return e
        }
    }

    func uninstall() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        removeKeys()
        pending?.cancel()
        pending = nil
        model?.inline = nil
    }

    /// Tag-Chip in Kommentar 2 unter dem Klick: (Track, x ab linkem Zellrand, Zellbreite) -> Tag oder nil
    var chipAt: ((Track, CGFloat, CGFloat) -> String?)?
    /// Zeilen zweizeilig (Vorschau „ganze Zeile“): Chips nur in der oberen Hälfte, unten liegt das Band
    var twoLine: () -> Bool = { false }

    /// Zeit des letzten Chip-Klicks (Folgeklicks eines Doppelklicks verfallen)
    private var lastChipClick: TimeInterval = -1

    /// Klick (ohne ⌘/⇧/⌃) in die Spalte Kommentar 2 auf einen Chip: Tag in den Filter / lösen, ⌥ = ausschließen.
    /// Doppelklick auf einen Chip: Folgeklicks verfallen, auch wenn nach dem Filtern eine andere Zeile darunter liegt
    /// (lädt nicht, schaltet nicht zurück). Nicht während einer Inline-Bearbeitung.
    private func chipDown(_ e: NSEvent) -> Bool {
        guard let chipAt, let tv = table, let model, model.inline == nil, e.window === tv.window else { return false }
        if e.clickCount > 1, e.timestamp - lastChipClick < NSEvent.doubleClickInterval * Double(e.clickCount - 1) { return true }
        guard e.modifierFlags.intersection([.command, .shift, .control]).isEmpty else { return false }
        let p = tv.convert(e.locationInWindow, from: nil)
        guard tv.visibleRect.contains(p) else { return false }
        let r = tv.row(at: p), c = tv.column(at: p), list = rows()
        guard r >= 0, r < list.count, field(ofColumn: c, in: tv) == .comment2,
              !twoLine() || p.y < tv.rect(ofRow: r).midY,
              let cv = tv.view(atColumn: c, row: r, makeIfNecessary: false) else { return false }
        let f = tv.convert(cv.bounds, from: cv)
        guard p.x - f.minX < f.width, let tag = chipAt(list[r], p.x - f.minX, f.width) else { return false }
        pending?.cancel()
        pending = nil
        if e.clickCount == 1 {
            lastChipClick = e.timestamp
            model.toggleTag(tag, exclude: e.modifierFlags.contains(.option))
        }
        return true
    }

    func field(ofColumn c: Int, in tv: NSTableView) -> TrackField? {
        guard c >= 0, c < tv.tableColumns.count else { return nil }
        let col = tv.tableColumns[c]
        if let f = Self.columnFields[col.identifier.rawValue] { return f }
        let title = col.title.isEmpty ? col.headerCell.stringValue : col.title
        return TrackField.allCases.first { $0.label == title }
    }

    /// sichtbare bearbeitbare Spalten in der Reihenfolge der Tabelle (für Tab)
    func visibleFields() -> [TrackField] {
        guard let tv = table else { return TrackField.allCases }
        let fields = tv.tableColumns.indices.filter { !tv.tableColumns[$0].isHidden }.compactMap { field(ofColumn: $0, in: tv) }
        return fields.isEmpty ? TrackField.allCases : fields
    }

    private func rowKey(_ r: Int) -> String? {
        let list = rows()
        return r >= 0 && r < list.count ? list[r].key : nil
    }

    /// Klick in die Tabelle: läuft vor der Tabelle, die Auswahl ist also noch die alte. Klick auf die schon allein
    /// gewählte Zeile -> nach der Doppelklick-Zeit bearbeiten (Doppelklick lädt weiterhin ins Deck).
    private func mouseDown(_ e: NSEvent) {
        pending?.cancel()
        pending = nil
        guard let tv = table, let model, e.window === tv.window else { return }
        let p = tv.convert(e.locationInWindow, from: nil)
        let inside = tv.visibleRect.contains(p)
        let r = inside ? tv.row(at: p) : -1, c = inside ? tv.column(at: p) : -1
        let f = field(ofColumn: c, in: tv), key = rowKey(r)
        // Klick neben die bearbeitete Zelle: Sterne -> abbrechen; Textfeld ohne Fokus -> übernehmen
        // (mit Fokus übernimmt das Feld selbst, sobald es den Fokus verliert)
        if let cur = model.inline, !(key == cur.key && f == cur.field) {
            let fr = tv.window?.firstResponder as? NSView
            if cur.field == .rating { finish(cur, commit: false, move: 0) }
            else if !(fr is NSText && fr?.isDescendant(of: tv) == true) { finish(cur, commit: true, move: 0) }
        }
        guard let key, let f else { return }
        lastField = f
        guard e.clickCount == 1, e.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty,
              model.selection == [key], model.inline?.key != key || model.inline?.field != f else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model?.selection == [key], self.model?.editSession == nil else { return }
            self.begin(key: key, field: f)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.05, execute: work)
    }

    /// Return in der Tabelle: zuletzt geklickte Spalte, sonst erste sichtbare bearbeitbare
    func beginFromKeyboard(_ ids: Set<String>) {
        guard ids.count == 1, let key = ids.first, let t = store?.byKey[key] else { return }
        let fields = visibleFields().filter { $0.isEditable(t) }
        guard let f = lastField.flatMap({ fields.contains($0) ? $0 : nil }) ?? fields.first else { return }
        begin(key: key, field: f)
    }

    func begin(key: String, field: TrackField) {
        guard let model, let t = store?.byKey[key] else { return }
        guard field.isEditable(t) else { NSSound.beep(); return }
        serial += 1
        model.inlineText = field.value(of: t)
        model.inline = InlineEdit(key: key, field: field, serial: serial)
        lastField = field
        installKeys()
    }

    /// Bearbeitung beenden: übernehmen (gültige Eingabe) oder verwerfen; `move` ±1 = nächste/vorige Spalte;
    /// `refocus` = Tabelle bekommt den Fokus zurück (nur bei Tastatur, sonst würde ein Klick ins Suchfeld verpuffen)
    func finish(_ edit: InlineEdit, commit: Bool, move: Int, refocus: Bool = false) {
        guard let model, model.inline == edit else { return }
        model.inline = nil
        removeKeys()
        if commit {
            if let v = edit.field.normalize(model.inlineText) {
                store?.applyEdits([edit.key: [edit.field: v]], writeBack: writeBack())
            } else {
                NSSound.beep()
            }
        }
        if move != 0, let t = store?.byKey[edit.key] {
            let fields = visibleFields()
            if let i = fields.firstIndex(of: edit.field) {
                var j = i + move
                while j >= 0, j < fields.count {
                    if fields[j].isEditable(t) { begin(key: edit.key, field: fields[j]); return }
                    j += move
                }
            }
        }
        if refocus, let tv = table { tv.window?.makeFirstResponder(tv) }
    }

    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let model = self.model, let edit = model.inline, let tv = self.table, e.window === tv.window else { return e }
            // nur solange der Fokus in dieser Tabelle liegt (Feld-Editor der Zelle oder die Tabelle selbst)
            guard let fr = tv.window?.firstResponder as? NSView, fr === tv || fr.isDescendant(of: tv) else { return e }
            switch e.keyCode {
            case 48: self.finish(edit, commit: true, move: e.modifierFlags.contains(.shift) ? -1 : 1, refocus: true); return nil   // Tab
            case 53: self.finish(edit, commit: false, move: 0, refocus: true); return nil                                           // Esc
            case 36, 76: self.finish(edit, commit: true, move: 0, refocus: true); return nil                                        // Return, Enter
            default:
                if edit.field == .rating, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (0...5).contains(n) {
                    model.inlineText = String(n)
                    self.finish(edit, commit: true, move: 0, refocus: true)
                    return nil
                }
                return e
            }
        }
    }

    private func removeKeys() {
        if let k = keyMonitor { NSEvent.removeMonitor(k) }
        keyMonitor = nil
    }
}

/// Unsichtbare Hilfsansicht hinter der Tabelle: findet das NSTableView der SwiftUI-Tabelle (größte Überdeckung
/// mit der eigenen Fläche, damit es bei zwei Browser-Bereichen das richtige ist).
struct TableViewFinder: NSViewRepresentable {
    let controller: InlineEditController

    func makeNSView(context: Context) -> FinderView {
        let v = FinderView()
        controller.finder = v
        return v
    }

    func updateNSView(_ v: FinderView, context: Context) { controller.finder = v }

    final class FinderView: NSView {
        private weak var cached: NSTableView?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func table() -> NSTableView? {
            guard let window, let root = window.contentView else { return nil }
            let mine = convert(bounds, to: nil)
            if let c = cached, c.window === window, overlap(c, mine) > 0 { return c }
            var best: (NSTableView, CGFloat)?
            func walk(_ v: NSView) {
                // SwiftUIs Table ist intern selbst ein NSOutlineView (SwiftUIOutlineTableView) – der Baum links hat
                // nur eine Spalte, die Track-Tabelle viele: daran unterscheiden
                if let t = v as? NSTableView, t.tableColumns.count > 1 {
                    let o = overlap(t, mine)
                    if o > (best?.1 ?? 0) { best = (t, o) }
                }
                v.subviews.forEach(walk)
            }
            walk(root)
            cached = best?.0
            return cached
        }

        private func overlap(_ t: NSTableView, _ rect: NSRect) -> CGFloat {
            let v: NSView = t.enclosingScrollView ?? t
            let r = v.convert(v.bounds, to: nil).intersection(rect)
            return r.isNull ? 0 : r.width * r.height
        }
    }
}

/// Eingabe in der Zelle: Textfeld oder Sterne (Bewertung)
struct InlineEditor: View {
    @Bindable var model: BrowserPaneModel
    let edit: InlineEdit
    let finish: (_ commit: Bool, _ move: Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if edit.field == .rating {
            StarPicker(value: Int(model.inlineText) ?? 0) { n in
                model.inlineText = String(n)
                finish(true, 0)
            }
        } else {
            TextField("", text: $model.inlineText)
                .textFieldStyle(.plain)
                .font(Theme.mono(11))
                .padding(.horizontal, 2)
                .background(Theme.chitinRaised)
                .overlay(Rectangle().stroke(edit.field.normalize(model.inlineText) == nil ? Theme.state : Theme.bone.opacity(0.6), lineWidth: 1))
                .focused($focused)
                .onAppear { DispatchQueue.main.async { focused = true } }
                .onSubmit { finish(true, 0) }
                .onExitCommand { finish(false, 0) }
                .onChange(of: focused) { was, now in if was, !now { finish(true, 0) } }
        }
    }
}

/// fünf Sterne; Klick auf den gesetzten Stern = 0
struct StarPicker: View {
    let value: Int
    var dim = false
    let set: (Int) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { n in
                Button { set(n == value ? 0 : n) } label: {
                    Text(n <= value ? "★" : "☆").contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .font(Theme.mono(13))
        .foregroundStyle(dim ? Theme.muted : Theme.bone)
    }
}

// MARK: - Bearbeiten-Fenster

/// Zustand des Bearbeiten-Fensters. Mehrfachauswahl: Position nil = alle gewählten (gleiche Werte stehen da,
/// unterschiedliche zeigen ‹mehrere›), PREV/NEXT geht einzeln durch. Ein Track: PREV/NEXT durch die ganze Liste.
/// Angehakte Felder gelten für alle gewählten Tracks, sonst gilt eine Eingabe nur für den angezeigten Track.
@MainActor @Observable
final class TrackEditSession: Identifiable {
    let id = UUID()
    let selection: [String]
    let list: [String]
    var pos: Int?
    /// Stand beim Öffnen bzw. nach dem letzten Übernehmen
    private(set) var values: [String: [TrackField: String]] = [:]
    var draft: [String: [TrackField: String]] = [:]
    var applyAll: Set<TrackField> = []
    var allValue: [TrackField: String] = [:]
    private(set) var locked: Set<String> = []

    var multi: Bool { selection.count > 1 }
    var walk: [String] { multi ? selection : list }
    var currentKey: String? { pos.flatMap { $0 < walk.count ? walk[$0] : nil } }

    init(selection: [String], list: [String], store: LibraryStore) {
        self.selection = selection
        self.list = list.contains(selection[0]) ? list : selection
        pos = selection.count > 1 ? nil : self.list.firstIndex(of: selection[0]) ?? 0
        for k in selection { load(k, store) }
    }

    func load(_ k: String, _ store: LibraryStore, force: Bool = false) {
        guard force || values[k] == nil, let t = store.byKey[k] else { return }
        let v = Dictionary(uniqueKeysWithValues: TrackField.allCases.map { ($0, $0.value(of: t)) })
        values[k] = v
        draft[k] = v
        if t.locked { locked.insert(k) } else { locked.remove(k) }
    }

    func step(_ d: Int, store: LibraryStore) -> String? {
        let n = walk.count
        if multi {
            let next = (pos ?? -1) + d
            pos = next < 0 ? nil : min(n - 1, next)
        } else {
            pos = max(0, min(n - 1, (pos ?? 0) + d))
        }
        if let k = currentKey { load(k, store) }
        return multi ? nil : currentKey
    }

    var positionText: String {
        guard let pos else { return String(localized: "ALLE \(selection.count)") }
        return "\(pos + 1) / \(walk.count)"
    }

    func common(_ f: TrackField) -> String? {
        let vs = Set(selection.map { draft[$0]?[f] ?? "" })
        return vs.count == 1 ? vs.first : nil
    }

    /// angezeigter Wert; nil = Platzhalter ‹mehrere›
    func display(_ f: TrackField) -> String? {
        if multi, applyAll.contains(f) { return allValue[f] ?? (pos == nil ? common(f) : nil) }
        if let k = currentKey { return draft[k]?[f] }
        return common(f)
    }

    func set(_ f: TrackField, _ v: String) {
        if multi, pos == nil || applyAll.contains(f) {
            allValue[f] = v
            applyAll.insert(f)
        } else if let k = currentKey {
            draft[k]?[f] = v
        }
    }

    func toggleAll(_ f: TrackField) {
        if applyAll.contains(f) {
            applyAll.remove(f)
            allValue[f] = nil
        } else {
            applyAll.insert(f)
            allValue[f] = currentKey.flatMap { draft[$0]?[f] } ?? common(f)
        }
    }

    func isEditable(_ f: TrackField) -> Bool {
        guard f == .bpm else { return true }
        if let k = currentKey { return !locked.contains(k) }
        return selection.contains { !locked.contains($0) }
    }

    func isValid(_ f: TrackField) -> Bool { display(f).map { f.normalize($0) != nil } ?? true }

    /// alle Änderungen gegenüber dem Stand beim Öffnen: Track -> Feld -> kanonischer Wert
    func changes() -> (changes: [String: [TrackField: String]], invalid: Bool) {
        var out: [String: [TrackField: String]] = [:]
        var invalid = false
        for (k, fields) in draft {
            for f in TrackField.allCases {
                let raw = multi && applyAll.contains(f) && selection.contains(k) ? allValue[f] : fields[f]
                guard let raw else { continue }
                guard let v = f.normalize(raw) else { invalid = true; continue }
                if v != values[k]?[f] { out[k, default: [:]][f] = v }
            }
        }
        return (out, invalid)
    }

    /// RESTORE: Eingaben seit dem Öffnen bzw. dem letzten Übernehmen verwerfen
    func restore() {
        draft = values
        applyAll = []
        allValue = [:]
    }

    /// nach dem Übernehmen: neuen Stand aus der Library lesen
    func reload(_ store: LibraryStore) {
        for k in values.keys { load(k, store, force: true) }
        applyAll = []
        allValue = [:]
    }
}

struct TrackEditPanel: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: TrackEditSession
    /// ein Track: PREV/NEXT wählt den Track auch in der Liste
    let onWalk: (String) -> Void

    var body: some View {
        let pending = session.changes()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("◆ TRACK BEARBEITEN").font(Theme.label(15, .bold))
                Spacer()
                DeckButton(title: "‹ ZURÜCK") { if let k = session.step(-1, store: store) { onWalk(k) } }
                Text(session.positionText).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(minWidth: 70)
                DeckButton(title: "WEITER ›") { if let k = session.step(1, store: store) { onWalk(k) } }
            }
            Text(subtitle).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            if session.multi {
                Text("■ = auf alle \(session.selection.count) gewählten Tracks anwenden · ‹mehrere› = unterschiedliche Werte")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(TrackField.allCases) { f in
                    GridRow {
                        if session.multi {
                            Button { session.toggleAll(f) } label: {
                                Text(session.applyAll.contains(f) ? "■" : "□")
                                    .foregroundStyle(session.applyAll.contains(f) ? Theme.state : Theme.muted)
                            }
                            .buttonStyle(.plain)
                            .font(Theme.mono(12))
                            .help("Auf alle gewählten Tracks anwenden")
                        }
                        Text(f.label.uppercased()).font(Theme.label(10, .bold)).foregroundStyle(Theme.bone.opacity(0.8))
                            .frame(width: 110, alignment: .leading)
                        editor(f)
                    }
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 6) {
                DeckButton(title: "WIEDERHERSTELLEN") { session.restore() }
                    .help("Eingaben seit dem Öffnen bzw. dem letzten Übernehmen verwerfen")
                if mix.prefs.ui.writeCollection {
                    Text("schreibt in die collection-datei").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                DeckButton(title: "ABBRECHEN") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                DeckButton(title: "ÜBERNEHMEN", active: !pending.changes.isEmpty) { apply() }
                DeckButton(title: "OK", active: true) { apply(); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if pending.invalid {
                Text("ungültige eingabe (rot) wird nicht übernommen").font(Theme.mono(10)).foregroundStyle(Theme.state)
            }
        }
        .padding(16)
        .frame(width: 640)
        .background(Theme.chitin)
    }

    private var subtitle: String {
        if let k = session.currentKey, let t = store.byKey[k] { return t.path }
        return String(localized: "\(session.selection.count) Tracks gewählt")
    }

    @ViewBuilder private func editor(_ f: TrackField) -> some View {
        let value = session.display(f)
        if f == .rating {
            HStack(spacing: 6) {
                StarPicker(value: Int(value ?? "0") ?? 0, dim: value == nil) { session.set(.rating, String($0)) }
                if value == nil { Text("‹mehrere›").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
            }
        } else {
            HStack(spacing: 6) {
                TextField(value == nil ? String(localized: "‹mehrere›") : placeholder(f),
                          text: Binding(get: { session.display(f) ?? "" }, set: { session.set(f, $0) }))
                    .textFieldStyle(.plain)
                    .font(Theme.mono(12))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(Theme.void)
                    .overlay(Rectangle().stroke(session.isValid(f) ? Theme.hairline : Theme.state, lineWidth: 1))
                    .disabled(!session.isEditable(f))
                if f == .bpm, !session.isEditable(f) {
                    Text("gesperrt").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private func placeholder(_ f: TrackField) -> String {
        switch f {
        case .releaseDate: String(localized: "JJJJ-MM-TT")
        case .bpm: "120.000"
        default: ""
        }
    }

    private func apply() {
        let c = session.changes()
        guard !c.changes.isEmpty else { return }
        store.applyEdits(c.changes, writeBack: mix.prefs.ui.writeCollection)
        session.reload(store)
    }
}
