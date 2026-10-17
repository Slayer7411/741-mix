import AppKit
import SwiftUI

/// Doppelklick auf Regler und Fader: ein durchsichtiges AppKit-Overlay merkt sich nur seine Fläche; ein lokaler
/// Ereignis-Monitor fängt den zweiten Klick eines Doppelklicks (clickCount 2) über einer dieser Flächen ab und ruft die
/// Aktion, bevor Geste oder NSSlider ihn sehen. Einzelklicks und Ziehen gehen unverändert durch. SwiftUI-Tap-Gesten neben
/// einer DragGesture(minimumDistance: 0) oder über einem NSSlider kommen sonst nie an
struct DoubleClickCatcher: NSViewRepresentable {
    let name: String   // UI-Test: „dbl GAIN“, „dbl XFADE“ …
    let action: () -> Void

    final class V: NSView, UITestNamed {
        var name = ""
        var action: () -> Void = {}
        nonisolated(unsafe) static let all = NSHashTable<V>.weakObjects()
        nonisolated(unsafe) static var monitor: Any?
        nonisolated(unsafe) static var swallowUp = false   // das Loslassen des abgefangenen Klicks auch schlucken

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // nie im Weg
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.all.add(self)
            if Self.monitor == nil {
                Self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { e in
                    if e.type == .leftMouseUp { if Self.swallowUp { Self.swallowUp = false; return nil }; return e }
                    guard e.clickCount == 2, let w = e.window else { return e }
                    for v in Self.all.allObjects where v.window === w && !v.isHiddenOrHasHiddenAncestor {
                        if v.bounds.contains(v.convert(e.locationInWindow, from: nil)) { v.action(); Self.swallowUp = true; return nil }
                    }
                    return e
                }
            }
        }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.name = name; v.action = action; return v }
    func updateNSView(_ v: V, context: Context) { v.name = name; v.action = action }
}

extension View {
    /// Doppelklick = `action` (Standardwert), Ziehen und Einzelklick bleiben bei der Ansicht
    func onDoubleClick(name: String = "", _ action: @escaping () -> Void) -> some View {
        overlay(DoubleClickCatcher(name: name, action: action))
    }
}

/// Drehregler: vertikal ziehen, Doppelklick = Standardwert. `bipolar` zeichnet den Bogen ab der Mitte.
struct Knob: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var defaultValue: Double = 0
    var bipolar = false
    var label: String = ""
    var color: Color = Theme.accent
    var size: CGFloat = 30

    @State private var dragStart: Double?
    @Environment(\.zoomExempt) private var exempt
    private var zoom: CGFloat { exempt ? 1 : 1.z }

    private var norm: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        let zoom = self.zoom, size = size * zoom
        VStack(spacing: 1 * zoom) {
            ZStack {
                Circle().fill(Theme.void)
                Circle().stroke(Theme.hairline, lineWidth: 1)
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                arc.stroke(Theme.bone, style: StrokeStyle(lineWidth: 2 * zoom, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                Rectangle().fill(Theme.bone)
                    .frame(width: 2 * zoom, height: size * 0.3)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + norm * 270))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let span = range.upperBound - range.lowerBound
                    let v = (dragStart ?? value) - Double(g.translation.height / zoom) / 150 * span
                    set(min(range.upperBound, max(range.lowerBound, v)))
                }
                .onEnded { _ in dragStart = nil })
            .onDoubleClick(name: "dbl " + label) { set(defaultValue) }
            if !label.isEmpty {
                Text(label).font(Theme.label(8 * zoom, .semibold)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
            }
        }
    }

    private var arc: some Shape {
        let from = bipolar ? 0.5 : 0
        let a = 0.125 + min(from, norm) * 0.75
        let b = 0.125 + max(from, norm) * 0.75
        return Circle().trim(from: a, to: b)
    }

    private func set(_ v: Double) { value = v }
}

/// Kompakter Schalter; `fill` = teilt sich mit den Nachbarn die ganze Breite des Stacks (Größenreihen am Deck)
struct DeckButton: View {
    let title: String
    var active = false
    var color: Color = Theme.state
    var width: CGFloat? = nil
    var fill = false
    /// Titel nicht übersetzen (Namen aus Plugins)
    var verbatim = false
    /// flach (11 pt statt 18, kleine Schrift) für Zeilen mit wenig Höhe, z. B. Insert-Slots in der Leiste
    var compact = false
    let action: () -> Void
    @Environment(\.zoomExempt) private var exempt

    var body: some View {
        let zoom = exempt ? 1 : 1.z
        Button(action: action) {
            (verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title)))
                .font(Theme.label((compact ? 8 : 10) * zoom, .bold))
                .lineLimit(1)
                .frame(minWidth: (width ?? 0) * zoom, maxWidth: fill ? .infinity : nil)
                .frame(height: (compact ? 11 : 18) * zoom)
                .padding(.horizontal, (compact ? 3 : 4) * zoom)
                .foregroundStyle(active ? (Self.bright(color) ? Theme.void : Theme.bone) : Theme.bone.opacity(0.75))
                .background(Rectangle().fill(active ? color.opacity(0.85) : Theme.void))
                .overlay(Rectangle().stroke(active ? color : Theme.hairline, lineWidth: 1))
                .fixedSize(horizontal: !fill, vertical: true)
        }
        .buttonStyle(.plain)
    }

    /// helle Füllung (weiße/gelbe Cues): Schrift dunkel, sonst unlesbar
    static func bright(_ c: Color) -> Bool {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return false }
        return 0.299 * n.redComponent + 0.587 * n.greenComponent + 0.114 * n.blueComponent > 0.6
    }
}

extension DeckButton {
    /// überspringen, solange Titel, Zustand, Farbe und Breite gleich bleiben – nur für Aktionen, die den Zustand erst
    /// beim Klick lesen (die Aktion einer übersprungenen Taste ist die vom letzten Neuzeichnen)
    func stable() -> some View { EquatableView(content: Stable(button: self)) }

    struct Stable: View, Equatable {
        let button: DeckButton
        var body: some View { button }
        static func == (a: Self, b: Self) -> Bool {
            a.button.title == b.button.title && a.button.active == b.button.active && a.button.color == b.button.color
                && a.button.width == b.button.width && a.button.fill == b.button.fill && a.button.verbatim == b.button.verbatim
        }
    }
}

/// Taste mit Drücken/Loslassen (CUE-Halten, Pitch-Bend)
struct PressButton: View {
    let title: String
    var active = false
    var color: Color = Theme.state
    var width: CGFloat? = nil
    let down: () -> Void
    let up: () -> Void
    @State private var pressed = false
    @Environment(\.zoomExempt) private var exempt

    var body: some View {
        let zoom = exempt ? 1 : 1.z
        Text(LocalizedStringKey(title))
            .font(Theme.label(10 * zoom, .bold))
            .frame(minWidth: (width ?? 0) * zoom)
            .frame(height: 18 * zoom)
            .padding(.horizontal, 4 * zoom)
            .foregroundStyle(active || pressed ? Theme.bone : Theme.bone.opacity(0.75))
            .background(Rectangle().fill(active || pressed ? color.opacity(0.85) : Theme.void))
            .overlay(Rectangle().stroke(active || pressed ? color : Theme.hairline, lineWidth: 1))
            .fixedSize()
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; down() } }
                .onEnded { _ in pressed = false; up() })
    }
}

/// Zeilenumbruch: Elemente in Leserichtung, passt eines nicht mehr in die Breite, beginnt die nächste Zeile
struct Wrap: Layout {
    var spacing: CGFloat = 4

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = [[]], x: CGFloat = 0
        for i in subviews.indices {
            let w = subviews[i].sizeThatFits(.unspecified).width
            if !rows[rows.count - 1].isEmpty, x + w > width { rows.append([]); x = 0 }
            rows[rows.count - 1].append(i)
            x += w + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width + spacing } - spacing
        var h: CGFloat = 0
        for r in rows(width, subviews) {
            h += r.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            h += spacing
        }
        return CGSize(width: width, height: max(0, h - spacing))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in rows(bounds.width, subviews) {
            var x = bounds.minX
            let rowH = r.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
            for i in r {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (rowH - s.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += rowH + spacing
        }
    }
}

/// Nur für den UI-Selbsttest: unsichtbare, nie klickbare Marke mit Namen (`UIDriver.named`)
struct UITestMark: NSViewRepresentable {
    let name: String

    final class V: NSView, UITestNamed {
        var name = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> V { let v = V(); v.name = name; return v }
    func updateNSView(_ v: V, context: Context) { v.name = name }
}

/// Wie ViewThatFits(in: .horizontal): zeigt den ersten Kandidaten, dessen ideale Breite passt, sonst den letzten.
/// Die Kandidaten bleiben aber bestehen (ViewThatFits erzeugt sie bei jedem Layout-Durchgang neu); nicht gewählte
/// liegen weit außerhalb und werden nicht gezeigt.
struct FirstFit: Layout {
    private func choice(_ width: CGFloat?, _ subviews: Subviews) -> Int {
        guard let width else { return 0 }
        return subviews.indices.first { subviews[$0].sizeThatFits(.unspecified).width <= width } ?? subviews.count - 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return subviews[choice(proposal.width, subviews)].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let i = choice(proposal.width, subviews)
        for (j, s) in subviews.enumerated() {
            if j == i { s.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(bounds.size)) }
            else { s.place(at: CGPoint(x: -100_000, y: -100_000), anchor: .topLeading, proposal: .unspecified) }
        }
    }
}

/// Eigene NSHostingView als Layout-Grenze: eine Änderung im Inhalt rechnet nur dessen Layout, nicht das des Fensters.
/// Größe = ideale Größe des Inhalts, gemessen nur, wenn sich `sizeKey` ändert (die Hosting-View meldet nichts nach
/// außen). Die Umgebung wird nicht vererbt: Modelle und Stil beim Aufruf mitgeben.
struct Isolated<Content: View>: NSViewRepresentable {
    let sizeKey: AnyHashable
    /// Breite vom Vorschlag (Zeilen über die ganze Deck-Breite), Höhe gemessen
    var fillWidth = false
    /// Name in der Layout-Messung (MIX741_BENCH_LAYOUT)
    var name = "iso"
    let content: Content
    init(_ name: String = "iso", sizeKey: AnyHashable = 0, fillWidth: Bool = false, @ViewBuilder _ content: () -> Content) {
        self.name = name
        self.sizeKey = sizeKey
        self.fillWidth = fillWidth
        self.content = content()
    }

    final class Coordinator {
        var key: AnyHashable?
        var size = CGSize.zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BoundaryHostingView<Content> {
        let v = BoundaryHostingView(rootView: content)
        v.name = name
        v.sizingOptions = []
        return v
    }

    func updateNSView(_ v: BoundaryHostingView<Content>, context: Context) { v.rootView = content }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundaryHostingView<Content>, context: Context) -> CGSize? {
        let c = context.coordinator
        let sizeKey = AnyHashable([sizeKey, AnyHashable(UIZoom.shared.factor)])   // neu messen nach einem Zoom-Wechsel
        if c.key != sizeKey {
            // ideale Größe ungerundet (intrinsicContentSize rundet auf ganze Punkte – Zeilen säßen dann versetzt)
            let probe = NSHostingController(rootView: content)
            probe.view.appearance = nsView.effectiveAppearance
            let ideal = probe.sizeThatFits(in: CGSize(width: 100_000, height: 100_000))
            c.size = CGSize(width: ideal.width < 50_000 ? ideal.width : 0, height: ideal.height)
            c.key = sizeKey
        }
        if fillWidth, let w = proposal.width { return CGSize(width: w, height: c.size.height) }
        return c.size
    }
}

/// Hosting-View als Layout-Grenze: meldet keine Größenänderung nach außen. NSHostingView ruft nach jedem Update
/// invalidateIntrinsicContentSize auf (auch ohne sizingOptions) – das ließ SwiftUI außen jedes Mal das ganze Fenster
/// neu messen. Unter MIX741_BENCH misst sie ihre Layout-Zeit (ohne darin verschachtelte Grenzen).
final class BoundaryHostingView<Content: View>: NSHostingView<Content>, AreaMenuHost {
    var name = "?"
    /// Menü der ganzen Fläche (Deck): wo SwiftUI kein eigenes Kontextmenü hat, auch für verschachtelte Hosting-Views
    var areaMenu: ((NSEvent) -> NSMenu?)?
    /// Ablage auf die ganze Fläche (Deck), siehe `AreaDrop`
    var drop: AreaDrop? {
        didSet {
            wantsLayer = true
            if let drop { registerForDraggedTypes(drop.types) } else { unregisterDraggedTypes() }
        }
    }

    override func menu(for e: NSEvent) -> NSMenu? {
        if let m = super.menu(for: e) { return m }
        return areaMenu?(e) ?? enclosingAreaMenu(for: e)
    }

    // Ablage: diese Ansicht selbst ist das Ziel (angemeldet). Eine SwiftUI-Ablage in einer Zeile fände AppKit nicht,
    // weil die Zeile unter dem Zeiger keine Ablage meldet
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        guard let drop else { return super.draggingEntered(s) }
        let ok = drop.accepts(s.draggingPasteboard)
        setDropHighlight(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        guard let drop else { return super.draggingUpdated(s) }
        return drop.accepts(s.draggingPasteboard) ? .copy : []
    }

    override func draggingExited(_ s: NSDraggingInfo?) {
        guard drop != nil else { return super.draggingExited(s) }
        setDropHighlight(false)
    }

    override func prepareForDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard drop != nil else { return super.prepareForDragOperation(s) }
        return true
    }

    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let drop else { return super.performDragOperation(s) }
        setDropHighlight(false)
        return drop.perform(s.draggingPasteboard)
    }

    override func concludeDragOperation(_ s: NSDraggingInfo?) {
        guard drop != nil else { return super.concludeDragOperation(s) }
        setDropHighlight(false)
    }

    /// Rahmen in der Akzentfarbe (wie der Rahmen der Decks) während eines annehmbaren Zugs
    private func setDropHighlight(_ on: Bool) {
        guard let l = layer else { return }
        l.borderWidth = on ? 2 : 0
        l.borderColor = on ? NSColor(red: 210 / 255, green: 31 / 255, blue: 38 / 255, alpha: 1).cgColor : nil
    }

    override func invalidateIntrinsicContentSize() {}
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        guard ToggleBench.requested else { return super.layout() }
        TimedLayout.stack.append(0)
        let t0 = CACurrentMediaTime()
        super.layout()
        let dt = CACurrentMediaTime() - t0
        let nested = TimedLayout.stack.removeLast()
        TimedLayout.times[name, default: 0] += dt - nested
        if !TimedLayout.stack.isEmpty { TimedLayout.stack[TimedLayout.stack.count - 1] += dt }
    }
}

/// Ansicht mit Menü für ihre ganze Fläche (Rechtsklick auf Unteransichten ohne eigenes Menü)
@MainActor protocol AreaMenuHost: AnyObject {
    var areaMenu: ((NSEvent) -> NSMenu?)? { get }
}

/// Ablage auf eine ganze Hosting-View: angemeldete Typen, ob der Zug angenommen wird, und das Ablegen (Pasteboard synchron)
struct AreaDrop {
    let types: [NSPasteboard.PasteboardType]
    let accepts: @MainActor (NSPasteboard) -> Bool
    let perform: @MainActor (NSPasteboard) -> Bool
}

extension NSView {
    /// Menü der nächsten umgebenden Fläche, die eines anbietet
    @MainActor func enclosingAreaMenu(for e: NSEvent) -> NSMenu? {
        var v = superview
        while let x = v {
            if let f = (x as? AreaMenuHost)?.areaMenu { return f(e) }
            v = x.superview
        }
        return nil
    }
}

/// nur Messung: Layout-Zeit je Hosting-View
enum TimedLayout {
    nonisolated(unsafe) static var times: [String: Double] = [:]
    nonisolated(unsafe) static var stack: [Double] = []
}

/// Mindestgröße des Fensters, ohne den Inhalt dafür zu messen. Das Fenster fragt nach Updates seine Mindestgröße neu ab
/// (Vorschlag 0×0); ein `.frame(minWidth:minHeight:)` misst dafür jedes Mal den ganzen Inhalt bei 1280×860 neu.
/// Inhalt füllt den Vorschlag (flexibel) – dann gleich wie das Frame.
struct MinSize: Layout {
    var width: CGFloat
    var height: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        if let w = proposal.width, let h = proposal.height { return CGSize(width: max(w, width), height: max(h, height)) }
        // ideale Größe (erste Fenstergröße): Inhalt fragen wie das Frame
        let p = ProposedViewSize(width: proposal.width.map { max($0, width) }, height: proposal.height.map { max($0, height) })
        let s = subviews.first?.sizeThatFits(p) ?? .zero
        return CGSize(width: max(width, s.width), height: max(height, s.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
