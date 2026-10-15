import AppKit
import SwiftUI
import MixCore

/// Tag-Farben wie ein Textmarker: normale Schrift, farbiger Hintergrund. Je Tag frei wählbar, sonst feste Farbe aus dem Namen.
enum TagColors {
    static let palette = ["6E5A12", "2E6638", "1F4C78", "6B2D5C", "7A3A1C", "40601E", "56307A", "1E6464", "7A1F30", "5C5C1E", "1E3F7A", "6B4A2D"]

    static func hex(_ tag: String, _ ui: UIPrefs) -> String {
        if let h = ui.tagColors[tag] { return h }
        var h: UInt32 = 5381
        for b in tag.utf8 { h = (h &* 33) ^ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }

    static func color(_ tag: String, _ ui: UIPrefs) -> Color { color(hex: hex(tag, ui)) }

    static func color(hex: String) -> Color {
        let v = UInt32(hex, radix: 16) ?? 0
        return Theme.rgb(Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF), Int(v & 0xFF))
    }

    static func hex(of c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        return String(format: "%02X%02X%02X", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }
}

/// Einstellungen: Farbe je Tag (alle Tags der Collection, nach Häufigkeit)
struct TagColorSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    @State private var filter = ""

    var body: some View {
        @Bindable var mix = mix
        let seps = mix.prefs.ui.tagSeparators
        let counts = Dictionary(store.tracks.flatMap { BrowserPaneModel.tags(of: $0, separators: seps) }.map { ($0, 1) }, uniquingKeysWith: +)
        let list = counts.filter { filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        Form {
            Section("Tags (Kommentar 2)") {
                LabeledContent("Trennzeichen") {
                    TextField("", text: $mix.prefs.ui.tagSeparators).settingsField().frame(width: 80)
                }
                .settingsAnchor("tags.separator")
                Toggle("Tags farbig markieren", isOn: $mix.prefs.ui.tagHighlight)
                    .settingsAnchor("tags.highlight")
            }
            Section("Tag-Farben") {
                TextField("Filtern", text: $filter).settingsField().frame(maxWidth: 260)
                    .settingsAnchor("tags.colors")
                ForEach(list.prefix(300), id: \.key) { tag, n in
                    HStack {
                        TagChip(tag: tag, mark: .none, style: .of(tag, mix.prefs.ui)).font(Theme.mono(12))
                        Text("\(n)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { TagColors.color(tag, mix.prefs.ui) },
                            set: { mix.prefs.ui.tagColors[tag] = TagColors.hex(of: $0) }), supportsOpacity: false)
                            .labelsHidden()
                        if mix.prefs.ui.tagColors[tag] != nil {
                            Button("↺") { mix.prefs.ui.tagColors[tag] = nil }.buttonStyle(.borderless).help("Standardfarbe")
                        }
                    }
                }
            }
        }
    }
}
