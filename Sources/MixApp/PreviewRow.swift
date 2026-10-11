import AppKit
import SwiftUI
import MixCore

/// Vorschau „ganze Zeile (zweizeilig)“: Text oben, darunter ein Band über alle Spalten. SwiftUIs Table kann keine
/// Zellen verbinden -> eine AppKit-Ansicht über dem sichtbaren Bereich der Tabelle zeichnet je sichtbare Zeile das Band
/// in die untere Hälfte (ein Bild über die ganze Zeilenbreite, Spaltengrenzen spielen keine Rolle). Klicks gehen durch.
enum PreviewRow {
    /// Mindesthöhe des Zelleninhalts zweizeilig; mit dem Rand der Tabelle ~34 pt je Zeile (Text ~17 pt + Band).
    /// Größere Schrift: Zeile wächst mit, das Band bleibt gleich hoch
    static func rowHeight(textSize: Double) -> CGFloat { 26 + max(0, CGFloat(textSize) - 12) * 1.5 }
    /// Band: untere Hälfte, 2 pt Luft unten
    @MainActor static func band(in row: NSRect) -> NSRect {
        NSRect(x: row.minX + 2.z, y: row.minY + row.height * 0.5, width: row.width - 4.z, height: row.height * 0.5 - 2.z)
    }
}

/// Zelle zweizeilig: Inhalt oben, Mindesthöhe = Zeilenhöhe (die Tabelle wächst mit)
struct PreviewRowCell: ViewModifier {
    let on: Bool
    /// Zeilenhöhe (PreviewRow.rowHeight) – als Wert, Zellen haben keine Umgebung
    let height: CGFloat
    func body(content: Content) -> some View {
        if on {
            content.frame(maxWidth: .infinity, minHeight: height, maxHeight: .infinity, alignment: .topLeading)
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
    /// Deckkraft des Bandes (Prefs)
    var alpha: CGFloat = 1 { didSet { if alpha != oldValue { view?.needsDisplay = true } } }
    /// Vorhören: Track mit Strich im Band, Klick ins Band springt
    var previewKey: String? { didSet { if previewKey != oldValue { followPreview() } } }
    private var playheadTimer: Timer?
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

    /// Strich 10 × je Sekunde nachführen, solange vorgehört wird (eine Ebene, nur ihr Rahmen)
    private func followPreview() {
        playheadTimer?.invalidate()
        playheadTimer = nil
        view?.movePlayhead()
        guard previewKey != nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.view?.movePlayhead() } }
        RunLoop.main.add(t, forMode: .common)
        playheadTimer = t
    }

    /// Band des vorgehörten Tracks in `v`, falls sichtbar (nur sichtbare Zeilen durchsucht)
    fileprivate func activeBand(in v: NSView) -> NSRect? {
        guard on, let key = previewKey, let tv = inline?.table else { return nil }
        let range = tv.rows(in: tv.visibleRect)
        for r in range.location..<min(rows.count, range.location + range.length) where rows[r].key == key {
            return v.convert(PreviewRow.band(in: tv.rect(ofRow: r)), from: tv)
        }
        return nil
    }

    func remove() {
        playheadTimer?.invalidate()
        playheadTimer = nil
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

    /// je sichtbare Zeile eine Ebene mit dem Bild als Inhalt: Core Animation setzt sie zusammen (GPU). Vorher zeichnete
    /// `draw(_:)` alle Bänder bei jedem Scrollschritt und jeder Listenänderung auf der CPU in den Puffer der Ansicht
    /// (~20–30 ms Hauptthread je Bild). Nicht gespiegelt: Zeilenrechtecke und Bildinhalt stehen beide mit y nach oben
    final class BandView: NSView {
        weak var table: NSTableView?
        weak var controller: PreviewRowController?
        private var bands: [CALayer] = []
        private let playhead = CALayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            playhead.backgroundColor = NSColor(Theme.state).cgColor
            playhead.zPosition = 1
            playhead.isHidden = true
            playhead.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        }

        required init?(coder: NSCoder) { fatalError() }

        override var wantsUpdateLayer: Bool { true }
        /// Klicks gehen durch an die Tabelle – außer ins Band des vorgehörten Tracks (Sprung)
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let r = controller?.activeBand(in: self), r.contains(convert(point, from: superview)) else { return nil }
            return self
        }

        override func mouseDown(with e: NSEvent) {
            guard let c = controller, let key = c.previewKey, let r = c.activeBand(in: self), r.width > 0 else { return }
            c.mix?.seekPreview(key, fraction: (convert(e.locationInWindow, from: nil).x - r.minX) / r.width)
            movePlayhead()
        }

        func movePlayhead() {
            guard let root = layer else { return }
            if playhead.superlayer == nil { root.addSublayer(playhead) }
            guard let r = controller?.activeBand(in: self), let f = controller?.mix?.previewFraction, f.isFinite else {
                playhead.isHidden = true
                return
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playhead.frame = CGRect(x: r.minX + CGFloat(f) * r.width - 1, y: r.minY, width: 2, height: r.height)
            playhead.isHidden = false
            CATransaction.commit()
        }

        override func updateLayer() {
            guard let root = layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            var used = 0
            if let tv = table, let c = controller {
                let range = tv.rows(in: tv.visibleRect)
                let opacity = Float(c.alpha)
                for r in range.location..<min(c.rows.count, range.location + range.length) {
                    let rect = convert(PreviewRow.band(in: tv.rect(ofRow: r)), from: tv)
                    guard rect.intersects(bounds), let img = c.image(c.rows[r]) else { continue }
                    if used == bands.count {
                        let l = CALayer()
                        l.contentsGravity = .resize
                        l.minificationFilter = .linear
                        l.magnificationFilter = .linear
                        root.addSublayer(l)
                        bands.append(l)
                    }
                    let l = bands[used]
                    l.frame = rect
                    if (l.contents as AnyObject?) !== img { l.contents = img }
                    l.opacity = opacity
                    l.isHidden = false
                    used += 1
                }
            }
            for l in bands[used...] where !l.isHidden { l.isHidden = true; l.contents = nil }
            movePlayhead()
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
        PreviewRowHost(controller: controller, rows: rows, mix: mix, on: on, tick: on ? Overviews.shared.tick : 0,
                       previewKey: on ? mix.previewing?.key : nil)
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
    /// vorgehörter Track (Strich, Klick)
    let previewKey: String?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        controller.mix = mix
        controller.rows = rows
        controller.on = on
        controller.alpha = CGFloat(mix.prefs.ui.previewBandAlpha)
        controller.previewKey = previewKey
        // Tabelle entsteht erst nach diesem Durchlauf
        DispatchQueue.main.async { controller.refresh() }
    }

    static func dismantleNSView(_ v: NSView, coordinator: ()) {}
}
