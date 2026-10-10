import AppKit
import SwiftUI
import MixCore

/// Vorschau „ganze Zeile (zweizeilig)“: Text oben, darunter ein Band über alle Spalten. SwiftUIs Table kann keine
/// Zellen verbinden -> eine AppKit-Ansicht über dem sichtbaren Bereich der Tabelle zeichnet je sichtbare Zeile das Band
/// in die untere Hälfte (ein Bild über die ganze Zeilenbreite, Spaltengrenzen spielen keine Rolle). Klicks gehen durch.
enum PreviewRow {
    /// Mindesthöhe des Zelleninhalts zweizeilig; mit dem Rand der Tabelle ~34 pt je Zeile (Text ~17 pt + Band)
    static let rowHeight: CGFloat = 26
    /// Band: untere Hälfte, 2 pt Luft unten
    static func band(in row: NSRect) -> NSRect {
        NSRect(x: row.minX + 2, y: row.minY + row.height * 0.5, width: row.width - 4, height: row.height * 0.5 - 2)
    }
}

/// Zelle zweizeilig: Inhalt oben, Mindesthöhe = Zeilenhöhe (die Tabelle wächst mit)
struct PreviewRowCell: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            content.frame(maxWidth: .infinity, minHeight: PreviewRow.rowHeight, maxHeight: .infinity, alignment: .topLeading)
        } else {
            content
        }
    }
}

/// zeichnet die Bänder; liegt als Geschwister über dem Inhalt der Scroll-Ansicht der Tabelle
@MainActor
final class PreviewRowController {
    weak var inline: InlineEditController?
    private var pending: Set<Int> = []
    var rows: [Track] = [] { didSet { view?.needsDisplay = true } }
    var mix: MixModel?
    var on = false { didSet { if on != oldValue { sync() } } }
    private var view: BandView?
    private var observers: [NSObjectProtocol] = []

    /// nach jeder SwiftUI-Aktualisierung (Zeilen, Einstellungen, neue Übersichten)
    func refresh() {
        sync()
        view?.needsDisplay = true
    }

    private func sync() {
        guard on, let tv = inline?.table, let scroll = tv.enclosingScrollView else { remove(); return }
        if let v = view, v.superview === scroll, v.table === tv { place(v, scroll); return }
        remove()
        let v = BandView()
        v.table = tv
        v.controller = self
        scroll.addSubview(v, positioned: .above, relativeTo: scroll.contentView)
        place(v, scroll)
        view = v
        // Scrollen, Größe, Spaltenbreiten: neu zeichnen
        scroll.contentView.postsBoundsChangedNotifications = true
        tv.postsFrameChangedNotifications = true
        let redraw: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let v = self.view, let s = v.superview as? NSScrollView else { return }
                self.place(v, s)
                v.needsDisplay = true
            }
        }
        let nc = NotificationCenter.default
        observers = [nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main, using: redraw),
                     nc.addObserver(forName: NSView.frameDidChangeNotification, object: tv, queue: .main, using: redraw),
                     nc.addObserver(forName: NSTableView.columnDidResizeNotification, object: tv, queue: .main, using: redraw),
                     nc.addObserver(forName: NSTableView.columnDidMoveNotification, object: tv, queue: .main, using: redraw)]
    }

    private func place(_ v: NSView, _ scroll: NSScrollView) {
        if v.frame != scroll.contentView.frame { v.frame = scroll.contentView.frame }
    }

    func remove() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        view?.removeFromSuperview()
        view = nil
    }

    /// Bild aus dem Cache, sonst im Hintergrund zeichnen und neu anstoßen
    fileprivate func image(_ t: Track) -> CGImage? {
        guard let mix else { return nil }
        var spec = PreviewSpec(t, mix: mix)
        spec.wide = true
        if spec.gen == 0 { Overviews.shared.want(t) }
        let h = spec.hashValue
        if let img = PreviewImages.cached(h) { return img }
        guard pending.insert(h).inserted else { return nil }
        Task { @MainActor [weak self] in
            _ = await PreviewImages.render(spec)
            self?.pending.remove(h)
            self?.view?.needsDisplay = true
        }
        return nil
    }

    final class BandView: NSView {
        weak var table: NSTableView?
        weak var controller: PreviewRowController?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let tv = table, let c = controller, let ctx = NSGraphicsContext.current?.cgContext else { return }
            let visible = tv.visibleRect
            let range = tv.rows(in: visible)
            guard range.length > 0 else { return }
            for r in range.location..<min(c.rows.count, range.location + range.length) {
                let band = PreviewRow.band(in: tv.rect(ofRow: r))
                let rect = convert(band, from: tv)
                guard rect.intersects(dirtyRect), let img = c.image(c.rows[r]) else { continue }
                ctx.saveGState()
                // Bild steht in CG-Koordinaten (y nach oben): in der gespiegelten Ansicht umdrehen
                ctx.translateBy(x: rect.minX, y: rect.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .medium
                ctx.draw(img, in: CGRect(origin: .zero, size: rect.size))
                ctx.restoreGState()
            }
        }
    }
}

/// eigene Ansicht, damit nur sie (nicht die ganze Tabelle) am Übersichten-Zähler hängt
struct PreviewRowLayer: View {
    let controller: PreviewRowController
    let rows: [Track]
    let mix: MixModel
    let on: Bool
    var body: some View {
        PreviewRowHost(controller: controller, rows: rows, mix: mix, on: on, tick: on ? Overviews.shared.tick : 0)
    }
}

/// unsichtbar hinter der Tabelle: hält den Band-Zeichner aktuell
struct PreviewRowHost: NSViewRepresentable {
    let controller: PreviewRowController
    let rows: [Track]
    let mix: MixModel
    let on: Bool
    /// Übersichten/Grid geändert (Overviews.tick)
    let tick: Int

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        controller.mix = mix
        controller.rows = rows
        controller.on = on
        // Tabelle entsteht erst nach diesem Durchlauf
        DispatchQueue.main.async { controller.refresh() }
    }

    static func dismantleNSView(_ v: NSView, coordinator: ()) {}
}
