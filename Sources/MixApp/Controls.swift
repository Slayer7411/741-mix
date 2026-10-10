import SwiftUI

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

    private var norm: Double { (value - range.lowerBound) / (range.upperBound - range.lowerBound) }

    var body: some View {
        VStack(spacing: 1) {
            ZStack {
                Circle().fill(Theme.void)
                Circle().stroke(Theme.hairline, lineWidth: 1)
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                arc.stroke(Theme.bone, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                Rectangle().fill(Theme.bone)
                    .frame(width: 2, height: size * 0.3)
                    .offset(y: -size * 0.2)
                    .rotationEffect(.degrees(-135 + norm * 270))
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = value }
                    let span = range.upperBound - range.lowerBound
                    let v = (dragStart ?? value) - Double(g.translation.height) / 150 * span
                    set(min(range.upperBound, max(range.lowerBound, v)))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { set(defaultValue) }
            if !label.isEmpty {
                Text(label).font(Theme.label(8, .semibold)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(Theme.label(10, .bold))
                .lineLimit(1)
                .frame(minWidth: width ?? 0, maxWidth: fill ? .infinity : nil)
                .frame(height: 18)
                .padding(.horizontal, 4)
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

/// Taste mit Drücken/Loslassen (CUE-Halten, Pitch-Bend)
struct PressButton: View {
    let title: String
    var active = false
    var color: Color = Theme.state
    var width: CGFloat? = nil
    let down: () -> Void
    let up: () -> Void
    @State private var pressed = false

    var body: some View {
        Text(LocalizedStringKey(title))
            .font(Theme.label(10, .bold))
            .frame(minWidth: width ?? 0)
            .frame(height: 18)
            .padding(.horizontal, 4)
            .foregroundStyle(active || pressed ? Theme.bone : Theme.bone.opacity(0.75))
            .background(Rectangle().fill(active || pressed ? color.opacity(0.85) : Theme.void))
            .overlay(Rectangle().stroke(active || pressed ? color : Theme.hairline, lineWidth: 1))
            .fixedSize()
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; down() } }
                .onEnded { _ in pressed = false; up() })
    }
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
    let content: Content
    init(sizeKey: AnyHashable = 0, @ViewBuilder _ content: () -> Content) {
        self.sizeKey = sizeKey
        self.content = content()
    }

    final class Coordinator {
        var key: AnyHashable?
        var size = CGSize.zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> BoundaryHostingView<Content> {
        let v = BoundaryHostingView(rootView: content)
        v.name = String(describing: type(of: content)).components(separatedBy: "<").dropFirst(3).first ?? "iso"
        v.sizingOptions = []
        return v
    }

    func updateNSView(_ v: BoundaryHostingView<Content>, context: Context) { v.rootView = content }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BoundaryHostingView<Content>, context: Context) -> CGSize? {
        let c = context.coordinator
        if c.key != sizeKey {
            let probe = NSHostingView(rootView: content)
            probe.appearance = nsView.effectiveAppearance
            c.size = probe.intrinsicContentSize
            c.key = sizeKey
        }
        return c.size
    }
}

/// Hosting-View als Layout-Grenze: meldet keine Größenänderung nach außen. NSHostingView ruft nach jedem Update
/// invalidateIntrinsicContentSize auf (auch ohne sizingOptions) – das ließ SwiftUI außen jedes Mal das ganze Fenster
/// neu messen. Unter MIX741_BENCH misst sie ihre Layout-Zeit (ohne darin verschachtelte Grenzen).
final class BoundaryHostingView<Content: View>: NSHostingView<Content> {
    var name = "?"

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
