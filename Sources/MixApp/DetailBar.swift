import AppKit
import SwiftUI
import MixCore
import MixMedia

/// Detailleiste unter der Liste eines Bereichs: alle wichtigen Felder des gewählten bzw. zuletzt angeklickten Tracks.
/// Eine AppKit-Ansicht, die selbst zeichnet; die Tabelle meldet den Track direkt (`show`), ohne SwiftUI-Durchlauf –
/// Pfeiltasten und Controller-Browse kosten je Wechsel nur das Neuzeichnen dieser Leiste.
/// Klick auf einen Tag-Chip filtert (⌥ = ausschließen), Klick auf den Dateipfad zeigt die Datei im Finder.
final class DetailBarView: NSView {
    weak var model: BrowserPaneModel?
    private weak var table: TrackTableController?
    private(set) var track: Track?
    /// Klickflächen der letzten Zeichnung
    private var tagHits: [(NSRect, String)] = []
    private var fileHit: NSRect?
    private var fetching: String?
    /// Zeit des letzten `show` samt Zeichnen (Selbsttest)
    private(set) var lastMs = 0.0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    /// Höhe: eine Zeile ab `wideWidth`, sonst zwei
    static func height(width: CGFloat) -> CGFloat { (lines(width: width) == 1 ? 24 : 42) * UIZoom.shared.factor }
    static func lines(width: CGFloat) -> Int { width >= 1500 * UIZoom.shared.factor ? 1 : 2 }

    func show(_ t: Track?, table: TrackTableController) {
        self.table = table
        guard t != track else { return }
        track = t
        needsDisplay = true
    }

    /// Werte neu (Bearbeitung, Harmonie, Filter), Track bleibt
    func refresh() { needsDisplay = true }

    // MARK: Zeichnen

    private struct Seg {
        var label: String?
        var text: String
        var color: NSColor
        var font: NSFont
        var middle = false
        var tags: [String] = []
        var file = false
    }

    private var z: CGFloat { UIZoom.shared.factor }
    private func mono(_ s: CGFloat, bold: Bool = false) -> NSFont { TableStyle.mono(s * z, bold: bold) }
    private func labelFont() -> NSFont { NSFont(name: "Cinzel", size: 9 * z) ?? .systemFont(ofSize: 8 * z) }

    private func segments(_ t: Track, ui: UIPrefs?) -> (first: [Seg], second: [Seg]) {
        let short = ui?.shortValues ?? true
        let bone = TableStyle.bone, dim = bone.withAlphaComponent(0.7)
        var name = [t.artist, t.title].filter { !$0.isEmpty }.joined(separator: " – ")
        if !t.mix.isEmpty, !t.title.localizedCaseInsensitiveContains(t.mix) { name += " (\(t.mix))" }
        var a: [Seg] = [Seg(text: name, color: bone, font: mono(12, bold: true), middle: true)]
        func add(_ into: inout [Seg], _ label: String, _ v: String, _ c: NSColor = dim, middle: Bool = false) {
            guard !v.isEmpty else { return }
            into.append(Seg(label: label, text: v, color: c, font: mono(11), middle: middle))
        }
        add(&a, String(localized: "ALBUM"), t.album)
        add(&a, String(localized: "LABEL"), t.label)
        add(&a, String(localized: "KAT"), t.catalogNo)
        add(&a, String(localized: "GENRE"), t.genre)
        add(&a, "BPM", short ? ShortValues.bpm(t.bpm) : t.bpm > 0 ? String(format: "%.2f", t.bpm) : "", bone)
        add(&a, "KEY", t.openKey, table?.keyColor(t) ?? bone)
        add(&a, String(localized: "LÄNGE"), t.duration > 0 ? Theme.time(t.duration) : "", bone)
        var b: [Seg] = []
        add(&b, String(localized: "KOMMENTAR"), t.comment, bone.withAlphaComponent(0.6))
        let tags = BrowserPaneModel.tagIndex.entry(t.comment2, separators: ui?.tagSeparators ?? " ").tags
        if !tags.isEmpty { b.append(Seg(label: String(localized: "TAGS"), text: "", color: bone, font: mono(11), tags: tags)) }
        if t.rating > 0 { add(&b, String(localized: "BEWERTUNG"), String(repeating: "★", count: min(5, t.rating)), bone) }
        add(&b, "PLAYS", t.playsText, bone)
        add(&b, String(localized: "ZULETZT"), short ? TrackTableController.shortDate(t.lastPlayed) : Track.dateText(t.lastPlayed))
        var file = Seg(label: String(localized: "DATEI"), text: t.path, color: TableStyle.muted, font: mono(10), middle: true)
        file.file = true
        b.append(file)
        return (a, b)
    }

    override func draw(_ dirty: NSRect) {
        let t0 = CACurrentMediaTime()
        TableStyle.chitin.setFill()
        bounds.fill()
        TableStyle.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        tagHits = []
        fileHit = nil
        guard let t = track else {
            text(String(localized: "kein track gewählt"), TableStyle.muted, mono(11), NSRect(x: 8 * z, y: 1, width: bounds.width - 16 * z, height: bounds.height - 1))
            return
        }
        let ui = table?.look?.ui
        let lines = Self.lines(width: bounds.width)
        let lineH = (bounds.height - 1) / CGFloat(lines)
        var x = 6 * z
        // Cover über alle Zeilen
        let side = min(bounds.height - 6 * z, 64 * z)
        let cover = NSRect(x: x, y: ((bounds.height - side) / 2).rounded() + 0.5, width: side, height: side)
        TableStyle.hairline.setStroke()
        NSBezierPath(rect: cover.insetBy(dx: 0.5, dy: 0.5)).stroke()
        if let hit = ArtworkCache.shared.cached(t.path, .small) {
            if let img = hit { NSImage(cgImage: img, size: cover.size).draw(in: cover) }
        } else if fetching != t.path {
            fetching = t.path
            let path = t.path
            Task { @MainActor [weak self] in
                _ = await ArtworkCache.shared.image(path, .small)
                guard let self, self.track?.path == path else { return }
                self.fetching = nil
                self.needsDisplay = true
            }
        }
        x = cover.maxX + 8 * z
        let (a, b) = segments(t, ui: ui)
        let rows = lines == 1 ? [a + b] : [a, b]
        for (i, segs) in rows.enumerated() {
            let r = NSRect(x: x, y: 1 + CGFloat(i) * lineH, width: bounds.width - x - 6 * z, height: lineH)
            layout(segs, in: r, ui: ui)
        }
        lastMs = (CACurrentMediaTime() - t0) * 1000
    }

    /// Teile nebeneinander; der Titel nimmt höchstens 40 %, was nicht mehr passt, wird gekürzt bzw. fällt weg
    private func layout(_ segs: [Seg], in r: NSRect, ui: UIPrefs?) {
        var x = r.minX
        let gap = 14 * z
        for (i, s) in segs.enumerated() {
            let left = r.maxX - x
            guard left > 30 * z else { break }
            if let l = s.label {
                let w = text(l, TableStyle.muted, labelFont(), NSRect(x: x, y: r.minY, width: left, height: r.height))
                x += w + 5 * z
            }
            if !s.tags.isEmpty {
                x += chips(s.tags, s.font, ui: ui, NSRect(x: x, y: r.minY, width: r.maxX - x, height: r.height))
            } else {
                var cap = r.maxX - x
                if i == 0 { cap = min(cap, max(r.width * 0.4, 200 * z)) }
                var v = s.text
                let adv = NSAttributedString(string: "0", attributes: [.font: s.font]).size().width
                if s.middle, adv > 0 { v = ShortValues.middle(v, max: Int(cap / adv)) }
                let rect = NSRect(x: x, y: r.minY, width: cap, height: r.height)
                let w = text(v, s.color, s.font, rect)
                if s.file { fileHit = NSRect(x: x, y: r.minY, width: w, height: r.height) }
                x += w
            }
            x += gap
        }
    }

    /// eine Zeile Text, mittig, rechts gekürzt; zurück: gezeichnete Breite
    @discardableResult
    private func text(_ s: String, _ c: NSColor, _ f: NSFont, _ r: NSRect) -> CGFloat {
        let a = TableStyle.attrs(f, c)
        let str = NSAttributedString(string: s, attributes: a)
        let size = str.size()
        let w = min(size.width, r.width)
        str.draw(with: NSRect(x: r.minX, y: (r.midY - size.height / 2).rounded(), width: w, height: size.height),
                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return ceil(w)
    }

    private func chips(_ tags: [String], _ f: NSFont, ui: UIPrefs?, _ r: NSRect) -> CGFloat {
        let filter = table?.tagFilter ?? TagFilter()
        var x = r.minX
        let h = ceil(f.ascender - f.descender) + 2
        for tag in tags {
            let mark = filter.isEmpty ? .none : filter.mark(tag)
            let s = TagChipStyle.of(tag, ui ?? UIPrefs())
            let color: NSColor = mark == .include ? TableStyle.void : mark == .exclude ? TableStyle.muted : TableStyle.bone
            let str = NSAttributedString(string: tag, attributes: TableStyle.attrs(f, color))
            let w = ceil(str.size().width) + 6 * z
            guard x + w <= r.maxX else { break }
            let box = NSRect(x: x, y: (r.midY - h / 2).rounded(), width: w, height: h)
            switch mark {
            case .include: NSColor(s.fill).setFill(); box.fill()
            case .exclude:
                TableStyle.state.setFill()
                NSRect(x: box.minX, y: box.midY.rounded(), width: box.width, height: 1).fill()
            case .none: NSColor(s.marker).setFill(); box.fill()
            }
            str.draw(at: NSPoint(x: box.minX + 3 * z, y: box.midY - str.size().height / 2))
            tagHits.append((box, tag))
            x += w + 4 * z
        }
        return x - r.minX
    }

    // MARK: Klicks

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let tag = tagHits.first(where: { $0.0.contains(p) })?.1 {
            model?.toggleTag(tag, exclude: e.modifierFlags.contains(.option))
            return
        }
        if let f = fileHit, f.contains(p), let t = track {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.path)])
        }
    }

    /// Selbsttest: Track zeigen und sofort zeichnen (auch ohne Fenster, in ein Bitmap), Dauer in ms
    private var probeRep: NSBitmapImageRep?
    func measure(_ t: Track, table: TrackTableController) -> Double {
        let t0 = CACurrentMediaTime()
        show(t, table: table)
        if probeRep == nil { probeRep = bitmapImageRepForCachingDisplay(in: bounds) }
        if let r = probeRep { cacheDisplay(in: bounds, to: r) }
        return (CACurrentMediaTime() - t0) * 1000
    }
}

/// SwiftUI-Hülle: meldet die Leiste beim Bereich an, Höhe aus der Breite (eine oder zwei Zeilen)
struct DetailBar: View {
    let model: BrowserPaneModel
    @State private var width: CGFloat = 1000

    var body: some View {
        DetailBarHost(model: model)
            .frame(height: DetailBarView.height(width: width))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(UITestMark(name: "detail bar"))
    }
}

struct DetailBarHost: NSViewRepresentable {
    let model: BrowserPaneModel

    func makeNSView(context: Context) -> DetailBarView {
        let v = DetailBarView()
        v.model = model
        model.detail = v
        model.onDetail?()
        return v
    }

    func updateNSView(_ v: DetailBarView, context: Context) {
        if model.detail !== v { model.detail = v; model.onDetail?() }
        v.refresh()
    }

    static func dismantleNSView(_ v: DetailBarView, coordinator: ()) {
        if v.model?.detail === v { v.model?.detail = nil }
    }
}
