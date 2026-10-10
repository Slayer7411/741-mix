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

/// Kompakter Schalter
struct DeckButton: View {
    let title: String
    var active = false
    var color: Color = Theme.state
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(LocalizedStringKey(title))
                .font(Theme.label(10, .bold))
                .frame(minWidth: width ?? 0)
                .frame(height: 18)
                .padding(.horizontal, 4)
                .foregroundStyle(active ? Theme.bone : Theme.bone.opacity(0.75))
                .background(Rectangle().fill(active ? color.opacity(0.85) : Theme.void))
                .overlay(Rectangle().stroke(active ? color : Theme.hairline, lineWidth: 1))
                .fixedSize()
        }
        .buttonStyle(.plain)
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
