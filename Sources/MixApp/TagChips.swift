import AppKit
import SwiftUI
import MixCore

/// Farben eines Tag-Chips: normal Textmarker in der Tag-Farbe (Knochenweiß darauf), gewählt = aufgehellte
/// Tag-Farbe (hell genug für dunkle Schrift). Je Farbe einmal berechnet.
struct TagChipStyle {
    let marker: Color
    let fill: Color

    static let plain = TagChipStyle(marker: .clear, fill: Theme.bone)

    /// Gruppen zu angezeigten Tags: aus den Markern davor, sonst die zuletzt gesehene Gruppe des Tags (Marker ausgeblendet)
    @MainActor static func groups(_ tags: [String]) -> [String?] {
        TagGroups.of(tags).enumerated().map { i, g in g ?? BrowserPaneModel.tagIndex.group(of: tags[i]) }
    }
    @MainActor private static var cache: [String: TagChipStyle] = [:]

    @MainActor static func of(_ tag: String, group: String? = nil, _ ui: UIPrefs) -> TagChipStyle {
        guard ui.tagHighlight else { return plain }
        let hex = TagColors.hex(tag, group: group, ui)
        if let s = cache[hex] { return s }
        let v = UInt32(hex, radix: 16) ?? 0
        let n = NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        n.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let st = TagChipStyle(marker: TagColors.color(hex: hex),
                              fill: Color(hue: Double(h), saturation: Double(min(s, 0.72)), brightness: Double(max(b, 0.88))))
        cache[hex] = st
        return st
    }
}

/// Ein Tag als Chip (Kopfzeile, Tag-Auswahl, Einstellungen): normal Textmarker in der Tag-Farbe, im Filter
/// hell gefüllt mit dunkler Schrift, ausgeschlossen rot umrandet und durchgestrichen. Radius 0.
struct TagChip: View {
    let tag: String
    let mark: TagFilter.Mark
    let style: TagChipStyle
    @Environment(\.zoomExempt) private var exempt

    var body: some View {
        let zoom = exempt ? 1 : 1.z
        Text(tag)
            .strikethrough(mark == .exclude, color: Theme.state)
            .foregroundStyle(mark == .include ? Theme.void : mark == .exclude ? Theme.muted : Theme.bone)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 3 * zoom)
            .background(mark == .include ? style.fill : mark == .exclude ? Color.clear : style.marker)
            .overlay { if mark == .exclude { Rectangle().strokeBorder(Theme.state, lineWidth: 1) } }
            .contentShape(Rectangle())
    }
}

/// Mehrere Tags als Chips (wenige: Kopfzeile). Mit `onTap` klickbar: (Tag, ⌥ gedrückt).
struct TagChips: View {
    let tags: [String]
    let ui: UIPrefs
    var filter = TagFilter()
    var onTap: ((String, Bool) -> Void)? = nil
    /// nur Messung (MIX741_SHOT=tags:…): Kommentar 2 als schlichter Text zum Vergleich
    @MainActor static var benchPlain = false
    @Environment(\.zoomExempt) private var exempt

    var body: some View {
        let groups = TagChipStyle.groups(tags)
        HStack(spacing: 3 * (exempt ? 1 : 1.z)) {
            ForEach(Array(tags.enumerated()), id: \.offset) { i, t in
                let chip = TagChip(tag: t, mark: filter.mark(t), style: .of(t, group: groups[i], ui))
                if let onTap {
                    Button { onTap(t, NSApp.currentEvent?.modifierFlags.contains(.option) == true) } label: { chip }
                        .buttonStyle(.plain)
                } else {
                    chip
                }
            }
        }
    }
}

/// Tabellenzelle Kommentar 2 als ein einziger Text (so billig wie schlichter Text): je Tag ein Lauf mit Hintergrund
/// wie `TagChip`. Klicks wertet `InlineEditController` aus (`spans`: x-Bereiche der Chips in der Zelle) –
/// eine Klickfläche je Zelle in SwiftUI oder eine NSView je Zelle kostete beim Blättern 15–20 % mehr.
struct TagChipsText: View {
    let tags: [String]
    let keys: [String]
    let ui: UIPrefs
    let filter: TagFilter

    var body: some View { Text(Self.text(tags: tags, keys: keys, ui: ui, filter: filter)).lineLimit(1) }

    /// Innenabstand je Seite: ein schmales Leerzeichen
    static let inset = "\u{2009}"

    /// Schrift der Tabelle: 11 pt, zweizeilig Größe und Gewicht aus den Einstellungen (Vorschau „ganze Zeile“), × Zoom
    struct Metrics: Hashable {
        var size: CGFloat = 11
        var bold = false
        @MainActor static func of(_ ui: UIPrefs) -> Metrics {
            ui.previewMode == .fullRow ? Metrics(size: CGFloat(ui.previewTextSize).z, bold: ui.previewTextBold) : Metrics(size: 11.z)
        }
        var font: Font { Theme.mono(size, bold ? .semibold : .regular) }
        var nsFont: NSFont {
            NSFont(name: bold ? "IBMPlexMono-SemiBold" : "IBMPlexMono-Regular", size: size)
                ?? .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
    }

    @MainActor private static var widths: [Metrics: (NSFont, [String: CGFloat])] = [:]
    @MainActor private static func width(_ s: String, _ m: Metrics) -> CGFloat {
        var (font, cache) = widths[m] ?? (m.nsFont, [:])
        if let w = cache[s] { return w }
        let w = (s as NSString).size(withAttributes: [.font: font]).width
        cache[s] = w
        widths[m] = (font, cache)
        return w
    }

    @MainActor static func text(tags: [String], keys: [String], ui: UIPrefs, filter: TagFilter) -> AttributedString {
        var out = AttributedString()
        let groups = TagChipStyle.groups(tags)
        for (i, t) in tags.enumerated() {
            if i > 0 { out += AttributedString(" ") }
            let m = filter.isEmpty ? .none : filter.mark(key: keys[i])
            let st = TagChipStyle.of(t, group: groups[i], ui)
            var run = AttributedString(inset + t + inset)
            switch m {
            case .include:
                run.backgroundColor = st.fill
                run.foregroundColor = Theme.void
            case .exclude:
                run.foregroundColor = Theme.muted
                run.strikethroughStyle = Text.LineStyle(pattern: .solid, color: Theme.state)
            case .none:
                run.backgroundColor = st.marker
                run.foregroundColor = Theme.bone
            }
            out += run
        }
        return out
    }

    /// x-Bereiche der Chips ab dem linken Rand der Zelle (`m`: Schrift der Tabelle)
    @MainActor static func spans(tags: [String], _ m: Metrics = Metrics()) -> [ClosedRange<CGFloat>] {
        var x: CGFloat = 0
        let gap = width(" ", m)
        return tags.map { t in
            let w = width(inset + t + inset, m)
            defer { x += w + gap }
            return x...(x + w)
        }
    }
}
