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
