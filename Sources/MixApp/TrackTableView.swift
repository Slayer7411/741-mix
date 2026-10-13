import AppKit
import SwiftUI
import MixCore
import MixEngine

// Track-Liste auf NSTableView: Zeilen über den Index aus der Liste, neue Liste = reloadData (gebaut werden nur die
// sichtbaren Zeilen), feste Zeilenhöhe, eigene Zellen (zeichnen Text/Bild selbst, eine Ebene je Zeile).
// Vorher SwiftUI-Table: jeder große Listenwechsel verglich bzw. baute alle Zeilen neu, ~0,25 s Hauptthread.

/// Spalte der Track-Tabelle. `id` = Schlüssel in der gespeicherten Anordnung (`columns.<bereich>`), Breiten bei 100 %
struct TrackColumn {
    enum Kind { case played, cloud, analyzed, color, cover, artist, title, preview, field(TrackField), bpm, key, harmony, time, gain, rating, comment2, plays, lastPlayed, importDate, bitrate, file }
    let id: String
    let title: String
    let kind: Kind
    var width: CGFloat
    var min: CGFloat
    var max: CGFloat = .greatestFiniteMagnitude
    var hidden = false
    var sort: KeyPathComparator<Track>?
    /// Name im Spalten-Menü des Kopfes (Symbol-Spalten)
    var menuTitle: String?
    var fixed: Bool { min == max }

    static func fixed(_ id: String, _ title: String, _ kind: Kind, _ w: CGFloat, hidden: Bool = false, sort: KeyPathComparator<Track>? = nil, menu: String? = nil) -> TrackColumn {
        TrackColumn(id: id, title: title, kind: kind, width: w, min: w, max: w, hidden: hidden, sort: sort, menuTitle: menu)
    }
    static func flex(_ id: String, _ title: String, _ kind: Kind, min: CGFloat, ideal: CGFloat, max: CGFloat = .greatestFiniteMagnitude, hidden: Bool = false, sort: KeyPathComparator<Track>? = nil) -> TrackColumn {
        TrackColumn(id: id, title: title, kind: kind, width: ideal, min: min, max: max, hidden: hidden, sort: sort)
    }

    /// Standard-Reihenfolge und -Sichtbarkeit (wie die SwiftUI-Tabelle vorher)
    static let all: [TrackColumn] = [
        .fixed("played", "▶", .played, 16, menu: String(localized: "▶ Gespielt")),
        .fixed("cloud", "☁", .cloud, 16, menu: String(localized: "☁ Cloud")),
        .fixed("analyzed", "✓", .analyzed, 16, sort: KeyPathComparator(\Track.analyzedSort), menu: String(localized: "✓ Analysiert")),
        .fixed("color", "", .color, 6, sort: KeyPathComparator(\Track.color), menu: String(localized: "Farbe")),
        .flex("cover", "Cover", .cover, min: 22, ideal: 44, hidden: true),
        .flex("artist", "Artist", .artist, min: 80, ideal: 150, sort: KeyPathComparator(\Track.artist)),
        .flex("title", "Title", .title, min: 80, ideal: 200, sort: KeyPathComparator(\Track.title)),
        .flex("preview", "Preview", .preview, min: 60, ideal: 150, max: 400),
        .flex("remixer", "Remixer", .field(.remixer), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.remixer)),
        .flex("producer", "Producer", .field(.producer), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.producer)),
        .flex("release", "Release", .field(.album), min: 60, ideal: 130, hidden: true, sort: KeyPathComparator(\Track.album)),
        .fixed("trackno", "Track #", .field(.trackNumber), 40, hidden: true, sort: KeyPathComparator(\Track.trackNumber)),
        .fixed("bpm", "BPM", .bpm, 56, sort: KeyPathComparator(\Track.bpm)),
        .fixed("key", "Key", .key, 36, sort: KeyPathComparator(\Track.openKey)),
        .fixed("harmony", "Match", .harmony, 44, sort: KeyPathComparator(\Track.harmonySort), menu: String(localized: "Match (Harmonie, Tempo zum Master)")),
        .fixed("keytext", "Key Text", .field(.keyText), 40, hidden: true, sort: KeyPathComparator(\Track.keyText)),
        .fixed("time", "Time", .time, 44, sort: KeyPathComparator(\Track.duration)),
        .fixed("gain", "Gain", .gain, 42, hidden: true, sort: KeyPathComparator(\Track.gainSort)),
        .fixed("rating", "Rating", .rating, 56, hidden: true, sort: KeyPathComparator(\Track.rating)),
        .flex("comment", "Comment", .field(.comment), min: 80, ideal: 170, sort: KeyPathComparator(\Track.comment)),
        .flex("comment2", "Comment 2", .comment2, min: 80, ideal: 260, sort: KeyPathComparator(\Track.comment2)),
        .flex("label", "Label", .field(.label), min: 60, ideal: 110, sort: KeyPathComparator(\Track.label)),
        .flex("catalog", "Catalog No", .field(.catalogNo), min: 50, ideal: 90, hidden: true, sort: KeyPathComparator(\Track.catalogNo)),
        .flex("genre", "Genre", .field(.genre), min: 50, ideal: 100, hidden: true, sort: KeyPathComparator(\Track.genre)),
        .fixed("plays", "Plays", .plays, 38, sort: KeyPathComparator(\Track.playCount)),
        .fixed("lastplayed", "Last Played", .lastPlayed, 74, hidden: true, sort: KeyPathComparator(\Track.lastPlayedSort)),
        .fixed("import", "Import", .importDate, 74, sort: KeyPathComparator(\Track.importSort)),
        .fixed("releasedate", "Release Date", .field(.releaseDate), 74, hidden: true, sort: KeyPathComparator(\Track.releaseSort)),
        .fixed("bitrate", "Bitrate", .bitrate, 44, hidden: true, sort: KeyPathComparator(\Track.bitrate)),
        .flex("file", "File Name", .file, min: 80, ideal: 220, hidden: true, sort: KeyPathComparator(\Track.fileName)),
        .flex("mix", "Mix", .field(.mix), min: 60, ideal: 110, hidden: true, sort: KeyPathComparator(\Track.mix)),
    ]
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

/// gespeicherte Spalten-Anordnung im Format der früheren SwiftUI-Tabelle (TableColumnCustomization als JSON):
/// `columnOrder` = IDs, `perColumnState` = abwechselnd ID und Zustand (Sichtbarkeit, Breite)
enum ColumnLayout {
    struct State: Equatable {
        var order: [String] = []
        var widths: [String: CGFloat] = [:]
        /// nur ausdrücklich gesetzte Sichtbarkeit (fehlt = Standard der Spalte)
        var hidden: [String: Bool] = [:]
    }

    private static func id(_ e: Any) -> String? {
        ((e as? [String: Any])?["base"] as? [String: Any]).flatMap { ($0["explicit"] as? [String: Any])?["_0"] as? String }
    }
    private static func ref(_ id: String) -> [String: Any] { ["base": ["explicit": ["_0": id]]] }

    static func decode(_ data: Data) -> State? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var s = State()
        s.order = (obj["columnOrder"] as? [Any] ?? []).compactMap(id)
        let per = obj["perColumnState"] as? [Any] ?? []
        for i in stride(from: 0, to: per.count - 1, by: 2) {
            guard let k = id(per[i]), let st = per[i + 1] as? [String: Any] else { continue }
            if let w = st["currentWidth"] as? Double { s.widths[k] = CGFloat(w) }
            if let v = st["visibility"] as? [String: Any] {
                if v["hidden"] != nil { s.hidden[k] = true } else if v["visible"] != nil { s.hidden[k] = false }
            }
        }
        return s
    }

    static func encode(_ s: State) -> Data {
        var per: [Any] = []
        for k in s.order {
            var st: [String: Any] = [:]
            if let w = s.widths[k] { st["currentWidth"] = Double(w) }
            st["visibility"] = s.hidden[k].map { $0 ? ["hidden": [String: Any]()] : ["visible": [String: Any]()] } ?? ["automatic": [String: Any]()]
            per.append(ref(k))
            per.append(st)
        }
        let obj: [String: Any] = ["columnOrder": s.order.map(ref), "perColumnState": per]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    /// neue Spalten an ihren Platz statt ans Ende: „played“ vorne, „cloud“ dahinter, „cover“ neben die Farbe,
    /// „preview“ hinter den Titel; übrige fehlende hinten
    static func placed(_ s: State) -> [String] {
        var order = s.order.filter { TrackColumn.byID[$0] != nil }
        guard !order.isEmpty else { return TrackColumn.all.map(\.id) }
        if !order.contains("played") { order.insert("played", at: 0) }
        if !order.contains("cloud") { order.insert("cloud", at: order.firstIndex(of: "played").map { $0 + 1 } ?? 0) }
        if !order.contains("cover") { order.insert("cover", at: order.firstIndex(of: "color").map { $0 + 1 } ?? min(3, order.count)) }
        if !order.contains("preview") { order.insert("preview", at: order.firstIndex(of: "title").map { $0 + 1 } ?? order.count) }
        if !order.contains("harmony") { order.insert("harmony", at: order.firstIndex(of: "key").map { $0 + 1 } ?? order.count) }
        for c in TrackColumn.all where !order.contains(c.id) { order.append(c.id) }
        return order
    }
}

/// Farben und Schriften der Tabelle (741: Void, Knochenweiß, Rot nur als Zustand, Lila = zweiter Zustand)
@MainActor
enum TableStyle {
    static let void = NSColor(Theme.void), chitin = NSColor(Theme.chitin), raised = NSColor(Theme.chitinRaised)
    static let bone = NSColor(Theme.bone), muted = NSColor(Theme.muted), hairline = NSColor(Theme.hairline)
    static let state = NSColor(Theme.state), secondary = NSColor(Theme.secondary), gold = NSColor(Theme.gold)
    /// Harmonie zum Master: gleich Lila, ±1 / Relativ hell, ±2 grau, unpassend gedimmt
    static let energy = bone.withAlphaComponent(0.62), clash = muted.withAlphaComponent(0.5)
    static func harmony(_ s: Harmony.Step) -> NSColor {
        switch s {
        case .same: secondary
        case .adjacent, .relative: bone
        case .energy: energy
        case .clash: clash
        }
    }
    /// Auswahl: leicht rot, auch ohne Fokus (dann etwas schwächer)
    static let selected = state.withAlphaComponent(0.24), selectedDim = state.withAlphaComponent(0.15)
    static let trackColors: [NSColor] = (0...7).map { NSColor(Theme.trackColor($0)) }

    /// Zeilenhöhe: einzeilig wie vorher (100 %: 24 pt), eigene Vorschau-Spalte 17 pt Bild + Rand, zweizeilig
    /// PreviewRow.rowHeight + 8 pt
    static func rowHeight(_ ui: UIPrefs) -> CGFloat {
        let z = UIZoom.shared.factor
        switch ui.previewMode {
        case .fullRow: return PreviewRow.rowHeight(textSize: ui.previewTextSize).z + 8
        case .column: return max((13 * z + 11).rounded(), 17 * z + 8)
        default: return (13 * z + 11).rounded()
        }
    }

    static func mono(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont(name: bold ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    private static var attrCache: [String: [NSAttributedString.Key: Any]] = [:]
    static func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let k = "\(font.fontName)|\(font.pointSize)|\(color.hash)"
        if let a = attrCache[k] { return a }
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
        attrCache[k] = a
        return a
    }
}

/// Zeile: zeichnet alle Zellen selbst (CoreText, keine Unteransicht je Zelle – nur die Inline-Bearbeitung ist eine).
/// Auswahl knochenweiß gedämpft, Haarlinie unten, keine abwechselnden Hintergründe
final class TrackRowView: NSTableRowView, NSViewToolTipOwner {
    weak var owner: TrackTableController?
    /// Zellen mit Hinweis (☁, ✓): Lage der zuletzt angemeldeten Bereiche
    var tips: [NSRect] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        TableStyle.hairline.withAlphaComponent(0.45).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? TableStyle.selected : TableStyle.selectedDim).setFill()
        bounds.fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        owner?.drawCells(self, dirtyRect)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        owner?.toolTip(self, at: point) ?? ""
    }
}

/// Spaltenkopf: Chitin, Plex Mono, Haarlinien, Sortierung als ▲/▼
final class TrackHeaderCell: NSTableHeaderCell {
    var sortMark = ""
    var font11: NSFont = TableStyle.mono(11)

    override func draw(withFrame f: NSRect, in v: NSView) {
        TableStyle.chitin.setFill()
        f.fill()
        TableStyle.hairline.setFill()
        NSRect(x: f.maxX - 1, y: f.minY + 5, width: 1, height: f.height - 10).fill()
        NSRect(x: f.minX, y: f.maxY - 1, width: f.width, height: 1).fill()
        drawInterior(withFrame: f, in: v)
    }

    override func drawInterior(withFrame f: NSRect, in v: NSView) {
        let font = stringValue == "☁" ? NSFont.systemFont(ofSize: font11.pointSize + 2) : font11
        let a = TableStyle.attrs(font, sortMark.isEmpty ? TableStyle.bone.withAlphaComponent(0.8) : TableStyle.bone)
        let h = ceil(font.ascender - font.descender)
        var r = NSRect(x: f.minX + 4, y: f.midY - h / 2, width: f.width - 8, height: h + 2)
        if !sortMark.isEmpty {
            let m = NSAttributedString(string: sortMark, attributes: TableStyle.attrs(TableStyle.mono(font11.pointSize * 0.8), TableStyle.muted))
            let w = m.size().width
            m.draw(at: NSPoint(x: f.maxX - w - 5, y: f.midY - m.size().height / 2))
            r.size.width -= w + 4
        }
        NSAttributedString(string: stringValue, attributes: a).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

final class TrackHeaderView: NSTableHeaderView {
    /// Doppelklick auf einen Spaltentrenner: Spalte auf den längsten Text (Index der Spalte)
    var onFitColumn: ((Int) -> Void)?

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, let tv = tableView, let i = dividerColumn(at: convert(e.locationInWindow, from: nil), tv) {
            onFitColumn?(i)
            return
        }
        super.mouseDown(with: e)
    }

    /// Spalte, deren rechter Rand (± 4 pt) am Punkt liegt, nur verstellbare
    private func dividerColumn(at p: NSPoint, _ tv: NSTableView) -> Int? {
        for (i, c) in tv.tableColumns.enumerated() where !c.isHidden && c.resizingMask.contains(.userResizingMask) {
            if abs(p.x - headerRect(ofColumn: i).maxX) <= 4 { return i }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        TableStyle.chitin.setFill()
        dirtyRect.fill()
        super.draw(dirtyRect)
    }
}

/// Tabelle: Return = Inline-Bearbeitung (Rest wie NSTableView: Pfeile, ⇧/⌘-Auswahl, Tippen springt)
final class TrackNSTable: NSTableView {
    var onReturn: (() -> Void)?
    /// Klick ins Vorschau-Bild des vorgehörten Tracks: Sprung statt Auswahl
    var onSeek: ((NSEvent) -> Bool)?

    override func mouseDown(with e: NSEvent) {
        if onSeek?(e) == true { return }
        super.mouseDown(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76, e.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            onReturn?()
            return
        }
        super.keyDown(with: e)
    }
}

/// Menüeintrag mit Aktion als Closure
final class ActionItem: NSMenuItem {
    private var run: () -> Void = {}
    convenience init(_ title: String, key: String = "", _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
        self.run = run
    }
    @objc private func fire() { run() }
}

/// Inline-Bearbeitung in der Zelle: Textfeld (Rahmen rot bei ungültiger Eingabe) oder fünf Sterne
final class InlineFieldCell: NSView, NSTextFieldDelegate {
    private let box = NSView()
    let field = NSTextField()
    var edit: InlineEdit?
    weak var model: BrowserPaneModel?
    var finish: ((InlineEdit, Bool) -> Void)?
    var twoLine = false
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = TableStyle.raised
        field.textColor = TableStyle.bone
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        box.wantsLayer = true
        box.layer?.backgroundColor = TableStyle.raised.cgColor
        box.layer?.borderWidth = 1
        box.addSubview(field)
        addSubview(box)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ e: InlineEdit, text: String, font: NSFont) {
        edit = e
        field.font = font
        field.stringValue = text
        updateBorder()
        needsLayout = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.edit == e, let w = self.window, self.model?.inline == e else { return }
            w.makeFirstResponder(self.field)
        }
    }

    override func layout() {
        super.layout()
        let line = twoLine ? NSRect(x: 0, y: 0, width: bounds.width, height: (bounds.height * 0.5).rounded()) : bounds
        let h = ceil((field.font?.ascender ?? 10) - (field.font?.descender ?? -3)) + 4
        box.frame = NSRect(x: 0, y: (line.midY - h / 2).rounded(), width: bounds.width, height: h)
        field.frame = box.bounds.insetBy(dx: 2.z, dy: 1)
    }

    private func updateBorder() {
        let bad = edit.map { $0.field.normalize(field.stringValue) == nil } ?? false
        box.layer?.borderColor = (bad ? TableStyle.state : TableStyle.bone.withAlphaComponent(0.6)).cgColor
    }

    func controlTextDidChange(_ n: Notification) {
        model?.inlineText = field.stringValue
        updateBorder()
    }

    /// Fokus weg (Klick daneben): übernehmen; Tab/Return/Esc erledigt vorher InlineEditController
    func controlTextDidEndEditing(_ n: Notification) {
        guard let edit, model?.inline == edit else { return }
        model?.inlineText = field.stringValue
        finish?(edit, true)
    }
}

final class StarsCell: NSView {
    var value = 0
    var font: NSFont = TableStyle.mono(13)
    var set: ((Int) -> Void)?
    var twoLine = false
    override var isFlipped: Bool { true }

    private var starWidth: CGFloat { NSAttributedString(string: "★", attributes: [.font: font]).size().width + 1.z }

    override func draw(_ dirtyRect: NSRect) {
        let s = String((1...5).map { $0 <= value ? "★" : "☆" })
        let a = TableStyle.attrs(font, TableStyle.bone)
        let line = twoLine ? NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.5) : bounds
        var x: CGFloat = 0
        for ch in s {
            let t = NSAttributedString(string: String(ch), attributes: a)
            t.draw(at: NSPoint(x: x, y: line.midY - t.size().height / 2))
            x += starWidth
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let n = Swift.max(1, Swift.min(5, Int(p.x / starWidth) + 1))
        set?(n == value ? 0 : n)
    }
}

/// Zustand und Aktionen einer Track-Tabelle (Daten-Quelle, Delegate, Menüs). Der SwiftUI-Teil (`TrackTable`) reicht
/// Zeilen und Darstellung herein, die Tabelle selbst spiegelt nur.
@MainActor
final class TrackTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var model: BrowserPaneModel?
    weak var store: LibraryStore?
    weak var history: HistoryStore?
    weak var mix: MixModel? { didSet { observeHarmony() } }
    weak var inline: InlineEditController?
    /// nur Selbsttest-Bilder: feste Zeilen
    var fixedRows: [Track]?
    /// nach jedem Neuaufbau (Band der Vorschau „ganze Zeile“)
    var onReload: (() -> Void)?
    private(set) var table: TrackNSTable?
    private var scroll: NSScrollView?

    /// alles außer den Zeilen, was die sichtbaren Zellen bestimmt
    struct Look: Equatable {
        var ui: UIPrefs
        var zoom: CGFloat
        var filter: TagFilter
        var inline: InlineEdit?
        var played: Set<String>
        var cloud: Int
        var tick: Int
        /// vorgehörter Track (Strich in Vorschau-Spalte bzw. hinter dem Titel)
        var preview: String?
    }

    private var rows: [Track] = []
    private var generation = -1
    private var look: Look?
    private var shownSelection: Set<String> = []
    private var applying = false
    private var saveWork: DispatchWorkItem?
    private var font: NSFont = TableStyle.mono(11)
    private var twoLine = false

    var shownRows: [Track] { rows }

    func makeView() -> NSScrollView {
        let tv = TrackNSTable()
        tv.style = .plain
        tv.headerView = TrackHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        tv.backgroundColor = TableStyle.void
        tv.usesAlternatingRowBackgroundColors = false
        tv.gridStyleMask = []
        tv.selectionHighlightStyle = .regular
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection = true
        tv.allowsColumnReordering = true
        tv.allowsColumnResizing = true
        tv.allowsTypeSelect = true
        tv.usesAutomaticRowHeights = false
        tv.rowSizeStyle = .custom
        tv.focusRingType = .none
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tv.intercellSpacing = NSSize(width: (10.z).rounded(), height: 0)
        tv.dataSource = self
        tv.delegate = self
        tv.target = self
        tv.doubleAction = #selector(doubleClicked)
        tv.onReturn = { [weak self] in self?.returnKey() }
        tv.onSeek = { [weak self] e in self?.seekClick(e) ?? false }
        (tv.headerView as? TrackHeaderView)?.onFitColumn = { [weak self] i in self?.fitColumn(i) }
        let menu = NSMenu()
        menu.delegate = self
        tv.menu = menu
        let head = NSMenu()
        head.delegate = self
        tv.headerView?.menu = head
        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = TableStyle.void
        sv.borderType = .noBorder
        table = tv
        scroll = sv
        return sv
    }

    // MARK: Spalten

    private func buildColumns(_ ui: UIPrefs) {
        guard let tv = table, tv.tableColumns.isEmpty else { return }
        let saved = model.flatMap { UserDefaults.standard.data(forKey: "columns.\($0.name)") }.flatMap(ColumnLayout.decode) ?? ColumnLayout.State()
        for id in ColumnLayout.placed(saved) {
            guard let d = TrackColumn.byID[id] else { continue }
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            let h = TrackHeaderCell(textCell: d.title)
            h.font11 = TableStyle.mono(11.z)
            c.headerCell = h
            c.title = d.title
            c.minWidth = d.min.z
            c.maxWidth = d.max == .greatestFiniteMagnitude ? d.max : d.max.z
            c.width = d.fixed ? d.width.z : Swift.min(c.maxWidth, Swift.max(c.minWidth, saved.widths[id] ?? d.width.z))
            c.resizingMask = d.fixed ? [] : [.autoresizingMask, .userResizingMask]
            c.isHidden = id == "preview" ? ui.previewMode != .column : saved.hidden[id] ?? d.hidden
            if d.sort != nil { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true) }
            tv.addTableColumn(c)
        }
    }

    private func scheduleSave() {
        guard !Session.isSelfTest else { return }
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.save() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func save() {
        guard let tv = table, let model else { return }
        var s = ColumnLayout.State()
        for c in tv.tableColumns {
            let id = c.identifier.rawValue
            s.order.append(id)
            s.widths[id] = c.width
            if let d = TrackColumn.byID[id], c.isHidden != d.hidden { s.hidden[id] = c.isHidden }
        }
        UserDefaults.standard.set(ColumnLayout.encode(s), forKey: "columns.\(model.name)")
    }

    func tableViewColumnDidMove(_ n: Notification) { redrawVisible(); scheduleSave() }
    func tableViewColumnDidResize(_ n: Notification) { redrawVisible(); if !applying { scheduleSave() } }

    /// Spalte auf den längsten Text der Liste (Doppelklick auf den Trenner): Kandidaten nach Zeichenzahl (Plex Mono
    /// ist dicktengleich), die längsten 8 genau gemessen; Titel der Kopfzeile muss auch passen
    func fitColumn(_ i: Int) {
        guard let tv = table, i >= 0, i < tv.tableColumns.count else { return }
        let c = tv.tableColumns[i]
        guard let d = TrackColumn.byID[c.identifier.rawValue], !d.fixed else { return }
        var best: [(Int, String)] = []   // (Zeichen, Text), die längsten
        var seen: Set<String> = []
        for t in rows {
            guard let s = cellText(d, t), !s.isEmpty, seen.insert(s).inserted else { continue }
            let n = s.utf16.count
            if best.count < 8 { best.append((n, s)); best.sort { $0.0 > $1.0 } }
            else if n > best[best.count - 1].0 { best[best.count - 1] = (n, s); best.sort { $0.0 > $1.0 } }
        }
        var w: CGFloat = 0
        for (_, s) in best { w = Swift.max(w, textWidth(d, s)) }
        let header = NSAttributedString(string: d.title, attributes: TableStyle.attrs(TableStyle.mono(11.z), TableStyle.bone)).size().width + 14.z
        let want = Swift.max(w + 6.z, header, c.minWidth)
        c.width = Swift.min(c.maxWidth, want.rounded(.up))
        redrawVisible()
        scheduleSave()
    }

    /// Breite eines Zellentexts in der Zeilenschrift (Tags als Chips, Key mit Platz für das Harmonie-Zeichen)
    private func textWidth(_ d: TrackColumn, _ s: String) -> CGFloat {
        switch d.kind {
        case .comment2:
            guard let c = chips(s) else { return 0 }
            return CGFloat(CTLineGetTypographicBounds(c.line, nil, nil, nil))
        case .key:
            let slot = look?.ui.harmonyColors == true ? (font.pointSize * 0.95).rounded() : 0
            return slot + NSAttributedString(string: s, attributes: ctAttrs(font, TableStyle.bone)).size().width
        default:
            return NSAttributedString(string: s, attributes: ctAttrs(font, TableStyle.bone)).size().width
        }
    }

    /// Text einer Zelle wie gezeichnet (nil: Spalte ohne Text)
    private func cellText(_ d: TrackColumn, _ t: Track) -> String? {
        switch d.kind {
        case .artist: t.artist
        case .title: t.title
        case let .field(fd): fd.value(of: t)
        case .bpm: t.bpm > 0 ? String(format: "%.2f", t.bpm) : ""
        case .key: t.openKey
        case .harmony: refBPM > 0 ? "+00.0" : ""
        case .time: Theme.time(t.duration)
        case .gain: t.perceivedDb.map { String(format: "%+.1f", $0) } ?? ""
        case .rating: String(repeating: "★", count: Swift.max(0, Swift.min(5, t.rating)))
        case .comment2: t.comment2
        case .plays: t.playsText
        case .lastPlayed: Track.dateText(t.lastPlayed)
        case .importDate: t.importText
        case .bitrate: t.bitrate > 0 ? "\(t.bitrate)" : ""
        case .file: t.fileName
        case .played, .cloud, .analyzed, .color, .cover, .preview: nil
        }
    }

    /// Zoom: Mindest-/Höchstbreiten neu, Breiten mitskalieren (wie vorher mit der SwiftUI-Tabelle)
    private func applyZoom(from old: CGFloat, to new: CGFloat) {
        guard let tv = table, old != new else { return }
        applying = true
        for c in tv.tableColumns {
            guard let d = TrackColumn.byID[c.identifier.rawValue] else { continue }
            let w = d.fixed ? d.width * new : (c.width * new / old * 2).rounded() / 2
            c.minWidth = Swift.min(c.minWidth, d.min * new)
            c.maxWidth = d.max == .greatestFiniteMagnitude ? d.max : d.max * new
            c.width = w
            c.minWidth = d.min * new
            (c.headerCell as? TrackHeaderCell)?.font11 = TableStyle.mono(11 * new)
        }
        applying = false
        tv.intercellSpacing = NSSize(width: (10 * new).rounded(), height: 0)
        scheduleSave()
    }

    // MARK: Abgleich mit dem Modell

    /// Zeilen immer aus `model.shown` (die SwiftUI-Hülle kann eine ältere Liste halten)
    func update(look l: Look) {
        guard let tv = table, let model else { return }
        let newRows = fixedRows ?? model.shown, gen = model.tableGeneration
        let first = look == nil
        if first { buildColumns(l.ui) }
        let old = look
        look = l
        if let old {
            if old.zoom != l.zoom { applyZoom(from: old.zoom, to: l.zoom) }
            if old.ui.previewMode != l.ui.previewMode, let c = tv.tableColumns.first(where: { $0.identifier.rawValue == "preview" }) {
                c.isHidden = l.ui.previewMode != .column
            }
        }
        let styleChanged = first || old?.ui != l.ui || old?.zoom != l.zoom
        if styleChanged {
            let m = TagChipsText.Metrics.of(l.ui)
            font = m.nsFont
            twoLine = l.ui.previewMode == .fullRow
            tv.rowHeight = TableStyle.rowHeight(l.ui)
            if let h = tv.headerView, h.frame.height != (24.z).rounded() { h.frame.size.height = (24.z).rounded(); tv.tile() }
        }
        if styleChanged || old?.filter != l.filter { chipCache = [:] }
        let same = rows.count == newRows.count && rows.withUnsafeBufferPointer { a in newRows.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        if !same || styleChanged {
            BrowserPaneModel.dropLater(rows)
            rows = newRows
            applying = true
            tv.reloadData()
            applying = false
            applySelection(model.selection)
            if gen != generation, !first { scrollAfterRebuild() }
            onReload?()
        } else if old != l {
            if old?.inline != l.inline { reloadEditor(old?.inline, l.inline) }
            // nur der Tag-Filter anders und die gefilterte Liste unterwegs: mit ihr neu zeichnen, nicht zweimal
            var o = old
            o?.filter = l.filter
            if !(model.listPending && o == l) { redrawVisible() }
        }
        generation = gen
        if model.selection != shownSelection { applySelection(model.selection) }
        syncSort(model.sortOrder)
        followPreview()
    }

    // MARK: Harmonie

    /// Bezug, mit dem die Zellen gezeichnet sind (Key-Code, Tempo)
    private var refKey: Int?
    private var refBPM = 0.0

    /// eigene Beobachtung von Key und Tempo des Bezugs (ohne SwiftUI): ein Wechsel zeichnet nur Key- und Match-Zellen
    /// der sichtbaren Zeilen neu, die Liste bleibt
    private func observeHarmony() {
        guard let mix else { return }
        withObservationTracking { refKey = mix.harmonyKey; refBPM = mix.harmonyBPM } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.harmonyChanged() } }
        }
    }

    private func harmonyChanged() {
        let k = refKey, b = refBPM
        observeHarmony()
        if k != refKey { redrawColumns(["key", "harmony"]) } else if b != refBPM { redrawColumns(["harmony"]) }
    }

    /// nur diese Spalten der sichtbaren Zeilen neu zeichnen
    private func redrawColumns(_ ids: [String]) {
        guard let tv = table else { return }
        let rects = ids.map { tv.column(withIdentifier: NSUserInterfaceItemIdentifier($0)) }
            .filter { $0 >= 0 && !tv.tableColumns[$0].isHidden }.map { tv.rect(ofColumn: $0) }
        guard !rects.isEmpty else { return }
        tv.enumerateAvailableRowViews { v, _ in
            for r in rects { v.setNeedsDisplay(NSRect(x: r.minX - v.frame.minX, y: 0, width: r.width, height: v.bounds.height)) }
        }
    }

    // MARK: Vorhören

    /// Strich des vorgehörten Tracks: eine Ebene in seiner Zeile, 10 × je Sekunde nachgeführt
    private let playhead: CALayer = {
        let l = CALayer()
        l.backgroundColor = NSColor(Theme.state).cgColor
        l.zPosition = 1
        l.isHidden = true
        l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        return l
    }()
    private var playheadTimer: Timer?

    /// Bereich verschwindet: Takt des Strichs anhalten
    func detach() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func followPreview() {
        let on = look?.preview != nil
        if on, playheadTimer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.movePlayhead() } }
            RunLoop.main.add(t, forMode: .common)
            playheadTimer = t
        } else if !on {
            playheadTimer?.invalidate()
            playheadTimer = nil
        }
        movePlayhead()
    }

    /// Bildfläche der Vorschau in der Zeile des vorgehörten Tracks (Tabellen-Koordinaten), nur sichtbare Zeilen
    private func previewRect() -> (row: Int, rect: CGRect)? {
        guard let tv = table, let key = look?.preview, let mode = look?.ui.previewMode else { return nil }
        let id = mode == .column ? "preview" : mode == .behindTitle ? "title" : ""
        let c = tv.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        guard c >= 0, !tv.tableColumns[c].isHidden else { return nil }
        let vis = tv.rows(in: tv.visibleRect)
        for r in vis.location..<Swift.min(rows.count, vis.location + vis.length) where rows[r].key == key {
            let l = line(tv.frameOfCell(atColumn: c, row: r))
            if mode == .column {
                let h = PreviewRenderer.heightPt.z
                return (r, CGRect(x: l.minX, y: (l.midY - h / 2).rounded(), width: l.width, height: h))
            }
            return (r, l.insetBy(dx: 0, dy: 1))
        }
        return nil
    }

    private func movePlayhead() {
        guard let tv = table, let (r, rect) = previewRect(), let f = mix?.previewFraction, f.isFinite,
              let rv = tv.rowView(atRow: r, makeIfNecessary: false), let layer = rv.layer else {
            playhead.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if playhead.superlayer !== layer { layer.addSublayer(playhead) }
        let o = tv.rect(ofRow: r).origin
        playhead.frame = CGRect(x: rect.minX - o.x + CGFloat(f) * rect.width - 1, y: rect.minY - o.y, width: 2, height: rect.height)
        playhead.isHidden = false
        CATransaction.commit()
    }

    /// Vorschau-Spalte: Klick ins Bild des vorgehörten Tracks springt (hinter dem Titel bleibt der Klick beim Titel)
    private func seekClick(_ e: NSEvent) -> Bool {
        guard let tv = table, look?.ui.previewMode == .column, let key = look?.preview, let (r, rect) = previewRect() else { return false }
        let p = tv.convert(e.locationInWindow, from: nil)
        guard tv.row(at: p) == r, rect.contains(p), rect.width > 0 else { return false }
        mix?.seekPreview(key, fraction: (p.x - rect.minX) / rect.width)
        movePlayhead()
        return true
    }

    /// Liste aus dem Hintergrund: direkt übernehmen (kein SwiftUI-Durchlauf für die Tabelle)
    func listArrived() {
        guard let look else { return }
        update(look: look)
    }

    private func applySelection(_ sel: Set<String>) {
        guard let tv = table else { return }
        var ix = IndexSet()
        if sel.count == 1, let k = sel.first {
            if let i = rows.firstIndex(where: { $0.key == k }) { ix.insert(i) }
        } else if !sel.isEmpty {
            for (i, t) in rows.enumerated() where sel.contains(t.key) { ix.insert(i) }
        }
        applying = true
        if tv.selectedRowIndexes != ix { tv.selectRowIndexes(ix, byExtendingSelection: false) }
        applying = false
        shownSelection = sel
    }

    /// neue Liste (Quelle, Sortierung, Filter): zur Auswahl, sonst nach oben
    private func scrollAfterRebuild() {
        guard let tv = table else { return }
        if let r = tv.selectedRowIndexes.first { tv.scrollRowToVisible(r) } else if tv.numberOfRows > 0 { tv.scrollRowToVisible(0) }
    }

    func scroll(to key: String) {
        guard let tv = table, let r = rows.firstIndex(where: { $0.key == key }) else { return }
        tv.scrollRowToVisible(r)
    }

    private func syncSort(_ order: [KeyPathComparator<Track>]) {
        guard let tv = table else { return }
        let want: [NSSortDescriptor] = order.compactMap { c in
            TrackColumn.all.first { $0.sort?.keyPath == c.keyPath }.map { NSSortDescriptor(key: $0.id, ascending: c.order == .forward) }
        }
        let head = want.first
        for c in tv.tableColumns {
            guard let h = c.headerCell as? TrackHeaderCell else { continue }
            let m = head?.key == c.identifier.rawValue ? (head!.ascending ? "▲" : "▼") : ""
            if h.sortMark != m { h.sortMark = m; tv.headerView?.needsDisplay = true }
        }
        if tv.sortDescriptors != want {
            applying = true
            tv.sortDescriptors = want
            applying = false
        }
    }

    func tableView(_ tv: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applying, let model else { return }
        let order: [KeyPathComparator<Track>] = tv.sortDescriptors.compactMap { d in
            guard let k = d.key, var c = TrackColumn.byID[k]?.sort else { return nil }
            c.order = d.ascending ? .forward : .reverse
            return c
        }
        if !order.isEmpty, order != model.sortOrder { model.sortOrder = order }
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !applying, let tv = table, let model else { return }
        var sel = Set<String>()
        for i in tv.selectedRowIndexes where i < rows.count { sel.insert(rows[i].key) }
        shownSelection = sel
        if model.selection != sel { model.selection = sel }
    }

    // MARK: Zellen

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tv: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let v = tv.makeView(withIdentifier: Self.rowID, owner: nil) as? TrackRowView ?? {
            let v = TrackRowView()
            v.identifier = Self.rowID
            return v
        }()
        v.owner = self
        v.needsDisplay = true
        if playhead.superlayer === v.layer { playhead.isHidden = true }
        return v
    }
    private static let rowID = NSUserInterfaceItemIdentifier("row")

    /// nur die Inline-Bearbeitung ist eine Ansicht, alle anderen Zellen zeichnet die Zeile
    func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard let col, row < rows.count, let e = model?.inline, e.key == rows[row].key,
              InlineEditController.columnFields[col.identifier.rawValue] == e.field else { return nil }
        return editor(e)
    }

    /// Inline-Bearbeitung an/aus/gewechselt: nur die betroffenen Zellen
    private func reloadEditor(_ old: InlineEdit?, _ new: InlineEdit?) {
        guard let tv = table else { return }
        var rs = IndexSet(), cs = IndexSet()
        for e in [old, new].compactMap({ $0 }) {
            if let r = rows.firstIndex(where: { $0.key == e.key }) { rs.insert(r) }
            if let c = tv.tableColumns.firstIndex(where: { InlineEditController.columnFields[$0.identifier.rawValue] == e.field }) { cs.insert(c) }
        }
        guard !rs.isEmpty, !cs.isEmpty else { return }
        tv.reloadData(forRowIndexes: rs, columnIndexes: cs)
        for r in rs { tv.rowView(atRow: r, makeIfNecessary: false)?.needsDisplay = true }
    }

    /// sichtbare Zeilen neu zeichnen (Werte, Farben, Vorschauen)
    private func redrawVisible() {
        guard let tv = table else { return }
        tv.enumerateAvailableRowViews { v, _ in v.needsDisplay = true }
    }

    func drawCells(_ rv: TrackRowView, _ dirty: NSRect) {
        guard let tv = table, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = tv.row(for: rv)
        guard r >= 0, r < rows.count else { return }
        let t = rows[r], origin = tv.rect(ofRow: r).origin
        let editing = model?.inline.flatMap { $0.key == t.key ? $0.field : nil }
        var tips: [NSRect] = []
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for (i, col) in tv.tableColumns.enumerated() where !col.isHidden {
            var f = tv.frameOfCell(atColumn: i, row: r)
            f.origin.x -= origin.x
            f.origin.y -= origin.y
            let id = col.identifier.rawValue
            if id == "cloud" || id == "analyzed" { tips.append(f) }
            guard f.intersects(dirty), let d = TrackColumn.byID[id] else { continue }
            if let editing, InlineEditController.columnFields[id] == editing { continue }
            ctx.saveGState()
            ctx.clip(to: f)
            drawCell(d, t, row: r, in: f, ctx)
            ctx.restoreGState()
        }
        if tips != rv.tips {
            rv.removeAllToolTips()
            for f in tips { rv.addToolTip(f, owner: rv, userData: nil) }
            rv.tips = tips
        }
    }

    func toolTip(_ rv: TrackRowView, at p: NSPoint) -> String? {
        guard let tv = table else { return nil }
        let r = tv.row(for: rv)
        let c = tv.column(at: rv.convert(p, to: tv))
        guard r >= 0, r < rows.count, c >= 0 else { return nil }
        let t = rows[r]
        switch tv.tableColumns[c].identifier.rawValue {
        case "cloud": return CloudCell.badge(t.path).help
        case "analyzed":
            guard t.analyzed else { return nil }
            return t.ownAnalysis ? String(localized: "analysiert von MINOS-741 (Tempo, Grid, Tonart, Lautheit ganz oder teilweise)") : String(localized: "analysiert in der Collection")
        default: return nil
        }
    }

    /// Zeile der Schrift: einzeilig die ganze Zelle, zweizeilig die obere Hälfte (unten liegt das Band)
    private func line(_ f: CGRect) -> CGRect {
        twoLine ? CGRect(x: f.minX, y: f.minY, width: f.width, height: (f.height * 0.5).rounded()) : f
    }

    private func drawCell(_ d: TrackColumn, _ t: Track, row: Int, in f: CGRect, _ ctx: CGContext) {
        let l = line(f)
        switch d.kind {
        case .played:
            if history?.played.contains(t.key) == true { draw("✓", TableStyle.secondary, l, ctx) }
        case .cloud:
            let b = CloudCell.badge(t.path)
            if !b.glyph.isEmpty { draw(b.glyph, NSColor(b.color), l, ctx, font: b.glyph == "☁" ? .systemFont(ofSize: 13.z) : TableStyle.mono(11.z)) }
        case .analyzed:
            if t.analyzed { draw("✓", t.ownAnalysis ? TableStyle.secondary : TableStyle.muted, l, ctx) }
        case .color:
            guard t.color > 0, t.color < TableStyle.trackColors.count else { return }
            ctx.setFillColor(TableStyle.trackColors[t.color].cgColor)
            ctx.fill(CGRect(x: (l.midX - 2.z).rounded(), y: l.minY + 1, width: 4.z, height: l.height - 2))
        case .cover:
            let s = 16.z
            let rect = CGRect(x: l.minX, y: (l.midY - s / 2).rounded(), width: s, height: s)
            if let hit = ArtworkCache.shared.cached(t.path, .small) {
                if let img = hit { image(img, rect, 1, ctx) }
            } else {
                fetch("cover|" + t.path, row: row, key: t.key) { await ArtworkCache.shared.image(t.path, .small) }
            }
        case .artist:
            draw(t.artist, t.loose ? TableStyle.muted : t.fileExists ? TableStyle.bone : TableStyle.state, l, ctx)
        case .title:
            if look?.ui.previewMode == .behindTitle, let img = preview(t, row: row) { image(img, l.insetBy(dx: 0, dy: 1), 0.25, ctx) }
            draw(t.title, t.loose ? TableStyle.muted : TableStyle.bone, l, ctx)
        case .preview:
            let h = PreviewRenderer.heightPt.z
            if let img = preview(t, row: row) { image(img, CGRect(x: l.minX, y: (l.midY - h / 2).rounded(), width: l.width, height: h), 1, ctx) }
        case let .field(fd):
            draw(fd.value(of: t), TableStyle.bone, l, ctx)
        case .bpm:
            draw(t.bpm > 0 ? String(format: "%.2f", t.bpm) : "", TableStyle.bone, l, ctx)
        case .key:
            drawKey(t, l, ctx)
        case .harmony:
            guard refBPM > 0, let off = look?.ui.match.tempoOffset(t.bpm, to: refBPM), let rule = look?.ui.match else { return }
            let v = (off * 10).rounded() / 10
            draw(v == 0 ? "0.0" : String(format: "%+.1f", v), abs(off) <= rule.bpmWindow ? TableStyle.bone : TableStyle.clash, l, ctx)
        case .time:
            draw(Theme.time(t.duration), TableStyle.bone, l, ctx)
        case .gain:
            draw(t.perceivedDb.map { String(format: "%+.1f", $0) } ?? "", TableStyle.bone, l, ctx)
        case .rating:
            draw(String(repeating: "★", count: Swift.max(0, Swift.min(5, t.rating))), TableStyle.bone, l, ctx)
        case .comment2:
            drawChips(t.comment2, l, ctx)
        case .plays:
            draw(t.playsText, TableStyle.bone, l, ctx)
        case .lastPlayed:
            draw(Track.dateText(t.lastPlayed), TableStyle.bone, l, ctx)
        case .importDate:
            draw(t.importText, TableStyle.bone, l, ctx)
        case .bitrate:
            draw(t.bitrate > 0 ? "\(t.bitrate)" : "", TableStyle.bone, l, ctx)
        case .file:
            draw(t.fileName, TableStyle.bone, l, ctx)
        }
    }

    /// Key, mit Bezug (Master) nach Harmonie gefärbt und mit Zeichen davor (◆ ▲ ▼ ◇) in einem festen Platz
    private func drawKey(_ t: Track, _ l: CGRect, _ ctx: CGContext) {
        guard look?.ui.harmonyColors == true, let ref = refKey else { draw(t.openKey, TableStyle.bone, l, ctx); return }
        let slot = (font.pointSize * 0.95).rounded()
        let text = CGRect(x: l.minX + slot, y: l.minY, width: l.width - slot, height: l.height)
        guard let code = t.harmonyCode else { draw(t.openKey, TableStyle.clash, text, ctx); return }
        let r = Harmony.relation(code, to: ref), color = TableStyle.harmony(r.step)
        if !r.symbol.isEmpty { draw(r.symbol, color, l, ctx, font: TableStyle.mono(font.pointSize * 0.7)) }
        draw(t.openKey, color, text, ctx)
    }

    private func ctAttrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
    }

    /// eine Zeile Text, vertikal mittig, rechts mit „…“ gekürzt
    private func draw(_ s: String, _ color: NSColor, _ l: CGRect, _ ctx: CGContext, font f: NSFont? = nil) {
        guard !s.isEmpty else { return }
        let font = f ?? self.font
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: ctAttrs(font, color)))
        draw(line, font, color, l, ctx)
    }

    private func draw(_ line: CTLine, _ font: NSFont, _ color: NSColor, _ l: CGRect, _ ctx: CGContext) {
        ctx.textPosition = CGPoint(x: l.minX, y: (l.midY + (font.ascender + font.descender) / 2).rounded())
        CTLineDraw(fitted(line, font, color, l.width), ctx)
    }

    /// zu lang: rechts mit „…“ gekürzt
    private func fitted(_ line: CTLine, _ font: NSFont, _ color: NSColor, _ width: CGFloat) -> CTLine {
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > Double(width) else { return line }
        let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: ctAttrs(font, color)))
        // gekürzt kann die Zeile über die Breite ragen (Abstand vor „…“): dann um den Überstand enger
        var w = Double(width), out = line
        for _ in 0..<3 {
            out = CTLineCreateTruncatedLine(line, w, .end, dots) ?? line
            let over = CTLineGetTypographicBounds(out, nil, nil, nil) - Double(width)
            if over <= 0.5 { break }
            w -= over
        }
        return out
    }

    private func image(_ img: CGImage, _ r: CGRect, _ alpha: CGFloat, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.interpolationQuality = .medium
        ctx.translateBy(x: 0, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: r.minX, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    /// Bilder, die gerade im Hintergrund entstehen (je Schlüssel einmal); fertig -> Zeile neu, Bild aus dem Cache
    private var fetching: Set<String> = []
    private func fetch(_ id: String, row: Int, key: String, _ work: @escaping () async -> CGImage?) {
        guard fetching.insert(id).inserted else { return }
        Task { @MainActor [weak self] in
            _ = await work()
            guard let self else { return }
            self.fetching.remove(id)
            guard let tv = self.table, row < self.rows.count, self.rows[row].key == key else { return }
            tv.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
        }
    }

    private func preview(_ t: Track, row: Int) -> CGImage? {
        guard let mix else { return nil }
        let spec = PreviewSpec(t, mix: mix)
        if spec.gen == 0 { Overviews.shared.want(t) }
        let h = spec.hashValue
        if let img = PreviewImages.cached(h) { return img }
        fetch("preview|\(h)", row: row, key: t.key) { await PreviewImages.render(spec) }
        return nil
    }

    /// Kommentar 2 als Chips: Hintergründe an den Stellen von `TagChipsText.spans` (dort wertet auch der Klick aus),
    /// darüber der Text als eine Zeile
    private struct Chips { let line: CTLine; let spans: [ClosedRange<CGFloat>]; let fills: [NSColor?]; let struck: [Bool] }
    private var chipCache: [String: Chips] = [:]

    private func chips(_ s: String) -> Chips? {
        guard !s.isEmpty, let l = look else { return nil }
        if let hit = chipCache[s] { return hit }
        let e = BrowserPaneModel.tagIndex.entry(s, separators: l.ui.tagSeparators)
        let out = NSMutableAttributedString()
        var fills: [NSColor?] = [], struck: [Bool] = []
        for (i, tag) in e.tags.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: " ", attributes: ctAttrs(font, TableStyle.bone))) }
            let m = l.filter.isEmpty ? .none : l.filter.mark(key: e.keys[i])
            let st = chipColors(tag, l.ui)
            let color: NSColor
            switch m {
            case .include: fills.append(st.fill); color = TableStyle.void
            case .exclude: fills.append(nil); color = TableStyle.muted
            case .none: fills.append(st.marker.alphaComponent > 0 ? st.marker : nil); color = TableStyle.bone
            }
            struck.append(m == .exclude)
            out.append(NSAttributedString(string: TagChipsText.inset + tag + TagChipsText.inset, attributes: ctAttrs(font, color)))
        }
        let c = Chips(line: CTLineCreateWithAttributedString(out), spans: TagChipsText.spans(tags: e.tags, TagChipsText.Metrics.of(l.ui)), fills: fills, struck: struck)
        chipCache[s] = c
        return c
    }

    private func drawChips(_ s: String, _ l: CGRect, _ ctx: CGContext) {
        guard let c = chips(s) else { return }
        let line = fitted(c.line, font, TableStyle.bone, l.width)
        let shown = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let h = ceil(font.ascender - font.descender)
        let y = (l.midY - h / 2).rounded()
        for (i, sp) in c.spans.enumerated() where sp.lowerBound < shown {
            let r = CGRect(x: l.minX + sp.lowerBound, y: y, width: Swift.min(sp.upperBound, shown) - sp.lowerBound, height: h)
            if let fill = c.fills[i] { ctx.setFillColor(fill.cgColor); ctx.fill(r) }
            if c.struck[i] {
                ctx.setFillColor(TableStyle.state.cgColor)
                ctx.fill(CGRect(x: r.minX, y: r.midY.rounded(), width: r.width, height: 1))
            }
        }
        ctx.textPosition = CGPoint(x: l.minX, y: (l.midY + (font.ascender + font.descender) / 2).rounded())
        CTLineDraw(line, ctx)
    }

    private var chipColorCache: [String: (marker: NSColor, fill: NSColor)] = [:]
    private func chipColors(_ tag: String, _ ui: UIPrefs) -> (marker: NSColor, fill: NSColor) {
        guard ui.tagHighlight else { return (.clear, TableStyle.bone) }
        let hex = TagColors.hex(tag, ui)
        if let c = chipColorCache[hex] { return c }
        let st = TagChipStyle.of(tag, ui)
        let c = (NSColor(st.marker), NSColor(st.fill))
        chipColorCache[hex] = c
        return c
    }

    private func editor(_ e: InlineEdit) -> NSView {
        guard let model, let ctl = inline else { return NSView() }
        if e.field == .rating {
            let v = StarsCell()
            v.value = Int(model.inlineText) ?? 0
            v.font = TableStyle.mono(13.z)
            v.twoLine = twoLine
            v.set = { [weak model, weak ctl] n in
                guard let model, let ctl else { return }
                model.inlineText = String(n)
                ctl.finish(e, commit: true, move: 0)
            }
            return v
        }
        let v = InlineFieldCell()
        v.model = model
        v.twoLine = twoLine
        v.finish = { [weak ctl] e, commit in ctl?.finish(e, commit: commit, move: 0) }
        v.configure(e, text: model.inlineText, font: TableStyle.mono(11.z))
        return v
    }

    /// Tippen springt (Spalte der Sortierung)
    func tableView(_ tv: NSTableView, typeSelectStringFor col: NSTableColumn?, row: Int) -> String? {
        guard let col, row < rows.count else { return nil }
        let id = col.identifier.rawValue
        let sortID = tv.sortDescriptors.first?.key ?? "artist"
        guard id == sortID, let d = TrackColumn.byID[id] else { return nil }
        switch d.kind {
        case .artist: return rows[row].artist
        case .title: return rows[row].title
        case let .field(f): return f.value(of: rows[row])
        case .comment2: return rows[row].comment2
        case .file: return rows[row].fileName
        default: return nil
        }
    }

    // MARK: Aktionen

    @objc private func doubleClicked() {
        guard let tv = table, tv.clickedRow >= 0, tv.clickedRow < rows.count, let mix else { return }
        mix.load(rows[tv.clickedRow], deck: mix.focusedDeck)
    }

    private func returnKey() {
        guard let model else { return }
        inline?.beginFromKeyboard(model.selection)
    }

    /// Rechtsklick: Zeile in der Auswahl -> ganze Auswahl, sonst nur diese Zeile
    private func menuKeys() -> Set<String> {
        guard let tv = table, let model else { return [] }
        let r = tv.clickedRow
        guard r >= 0, r < rows.count else { return [] }
        return tv.selectedRowIndexes.contains(r) ? model.selection : [rows[r].key]
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table?.headerView?.menu { columnMenu(menu); return }
        guard let store, let model, let mix, let history else { return }
        let ids = menuKeys()
        guard !ids.isEmpty else { return }
        let tracks = { ids.compactMap { store.track($0) } }
        for n in 0..<4 {
            menu.addItem(ActionItem(String(localized: "In Deck \(["A", "B", "C", "D"][n]) laden")) { [weak mix] in
                if let id = ids.first, let t = store.track(id) { mix?.load(t, deck: n) }
            })
        }
        menu.addItem(.separator())
        let rows = self.rows
        let edit = ActionItem(String(localized: "Bearbeiten …"), key: "e") { [weak model] in model?.openEditor(ids, rows: rows, store: store) }
        edit.keyEquivalentModifierMask = .command
        menu.addItem(edit)
        if store.hasEdits(ids) { menu.addItem(ActionItem(String(localized: "Eigene Änderungen verwerfen")) { store.revertEdits(Array(ids)) }) }
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Analysieren")) { Analyses.shared.enqueue(tracks(), refresh: false) })
        menu.addItem(ActionItem(String(localized: "Neu analysieren")) { Analyses.shared.enqueue(tracks(), refresh: true) })
        if store.hasAnalysis(ids) { menu.addItem(ActionItem(String(localized: "Analyse verwerfen")) { store.discardAnalysis(Array(ids)) }) }
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "An Preparation anhängen")) { store.preparation.append(contentsOf: ids.filter { !store.preparation.contains($0) }) })
        if case .preparation = model.source {
            menu.addItem(ActionItem(String(localized: "Aus Preparation entfernen")) { store.preparation.removeAll { ids.contains($0) } })
        }
        menu.addItem(.separator())
        if CloudLibrary.shared.hasCloudTracks {
            menu.addItem(ActionItem(String(localized: "Bereitmachen (herunterladen)")) { CloudLibrary.shared.makeReady(tracks(), label: String(localized: "Auswahl")) })
        }
        menu.addItem(ActionItem(String(localized: "Vorhören")) { [weak mix] in if let id = ids.first, let t = store.track(id) { mix?.preview(t) } })
        menu.addItem(ActionItem(String(localized: "Im Finder zeigen")) {
            NSWorkspace.shared.activateFileViewerSelecting(tracks().map { URL(fileURLWithPath: $0.path) })
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Reset Played State")) { [weak history] in history?.resetPlayed() })
    }

    /// Rechtsklick auf den Kopf: Spalten ein/aus (Vorschau-Spalte folgt der Einstellung)
    private func columnMenu(_ menu: NSMenu) {
        guard let tv = table else { return }
        for c in tv.tableColumns.sorted(by: { a, b in
            (TrackColumn.all.firstIndex { $0.id == a.identifier.rawValue } ?? 0) < (TrackColumn.all.firstIndex { $0.id == b.identifier.rawValue } ?? 0)
        }) {
            let id = c.identifier.rawValue
            guard id != "preview", let d = TrackColumn.byID[id] else { continue }
            let item = ActionItem(d.menuTitle ?? d.title) { [weak self, weak c] in
                guard let c else { return }
                c.isHidden.toggle()
                self?.scheduleSave()
            }
            item.state = c.isHidden ? .off : .on
            menu.addItem(item)
        }
    }
}

/// SwiftUI-Hülle: NSScrollView mit der Tabelle, misst nicht (nimmt den angebotenen Platz)
struct TrackTableView: NSViewRepresentable {
    let controller: TrackTableController
    let look: TrackTableController.Look
    /// nur beobachtet: Auswahl und Sortierung des Bereichs
    let selection: Set<String>
    let sort: [KeyPathComparator<Track>]
    /// Modell, Stores, Inline-Controller anbinden (vor dem ersten Abgleich)
    let wire: (TrackTableController) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let v = controller.makeView()
        wire(controller)
        return v
    }

    func updateNSView(_ v: NSScrollView, context: Context) { controller.update(look: look) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
}
