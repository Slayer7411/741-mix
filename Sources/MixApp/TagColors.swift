import AppKit
import SwiftUI
import MixCore

/// Tag-Farben wie ein Textmarker: normale Schrift, farbiger Hintergrund. Je Tag frei wählbar, sonst feste Farbe aus dem Namen.
enum TagColors {
    static let palette = ["6E5A12", "2E6638", "1F4C78", "6B2D5C", "7A3A1C", "40601E", "56307A", "1E6464", "7A1F30", "5C5C1E", "1E3F7A", "6B4A2D"]

    /// Farben der Wellenform (aktives Preset), gesetzt vom MixModel
    @MainActor static var wave: () -> BlendPaint.Palette? = { nil }

    /// Wellenform-Farben, die eine Gruppe tragen kann (⌘, → TAGS, je Marker)
    static let waveSources: [(id: String, name: String)] = [
        ("low", "Tief (Kick)"), ("lowWarm", "Tiefen gehalten (Bass)"), ("mid", "Mitten"), ("high", "Höhen (Hats)"),
        ("highOpen", "Höhen gehalten"), ("aus", "eigene Farbe"),
    ]

    /// Farbe einer Gruppe aus der Wellenform (Standard K = Tief, B = gehaltene Tiefen, H = Höhen), je Marker einstellbar.
    /// Abgedunkelt auf die Helligkeit der Palette (knochenweiße Schrift bleibt lesbar)
    @MainActor static func waveHex(_ marker: String, _ ui: UIPrefs) -> String? {
        guard let src = ui.tagGroupWave[marker], let p = wave() else { return nil }
        let c: BlendPaint.RGB
        switch src {
        case "low": c = p.low
        case "lowWarm": c = p.lowWarm
        case "mid": c = p.mid
        case "high": c = p.high
        case "highOpen": c = p.highOpen
        default: return nil
        }
        let n = NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        n.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let d = NSColor(hue: h, saturation: min(s, 0.85), brightness: min(b, 0.5), alpha: 1)
        return String(format: "%02X%02X%02X", Int(d.redComponent * 255), Int(d.greenComponent * 255), Int(d.blueComponent * 255))
    }

    /// eigene Farbe des Tags, sonst die seiner Gruppe (Farbe des Markers, K / B / H aus der Wellenform), sonst aus dem Namen
    @MainActor static func hex(_ tag: String, group: String? = nil, _ ui: UIPrefs) -> String {
        if let h = ui.tagColors[tag] { return h }
        if ui.tagGroups, let g = group, g != TagGroups.role { if g != tag { return hex(g, group: g, ui) } else if let w = waveHex(g, ui) { return w } }
        var h: UInt32 = 5381
        for b in tag.utf8 { h = (h &* 33) ^ UInt32(b) }
        return palette[Int(h % UInt32(palette.count))]
    }

    @MainActor static func color(_ tag: String, group: String? = nil, _ ui: UIPrefs) -> Color { color(hex: hex(tag, group: group, ui)) }

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
    /// false: Abschnitt „Tags (Kommentar 2)“; true: „Tag-Farben“ (getrennt einsortiert)
    var colors = false
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    @State private var filter = ""

    /// Marker der Collection (einzelne Großbuchstaben am Gruppenanfang) und benannte
    private var groupMarkers: [String] {
        let seps = mix.prefs.ui.tagSeparators
        var found = Set(mix.prefs.ui.tagGroupNames.keys)
        for t in store.tracks where !t.comment2.isEmpty {
            for tag in BrowserPaneModel.tags(of: t, separators: seps) where TagGroups.isMarker(tag) { found.insert(tag) }
        }
        return found.sorted()
    }

    var body: some View {
        @Bindable var mix = mix
        let seps = mix.prefs.ui.tagSeparators
        let counts = Dictionary(store.tracks.flatMap { BrowserPaneModel.tags(of: $0, separators: seps) }.map { ($0, 1) }, uniquingKeysWith: +)
        let list = counts.filter { filter.isEmpty || $0.key.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        Group {
            if !colors {
            Section("Tags (Kommentar 2)") {
                LabeledContent("Trennzeichen") {
                    TextField("", text: $mix.prefs.ui.tagSeparators).settingsField().frame(width: 80)
                }
                .settingsAnchor("tags.separator")
                Toggle("Tags farbig markieren", isOn: $mix.prefs.ui.tagHighlight)
                    .settingsAnchor("tags.highlight")
                Toggle("Gruppen (K / B / H …)", isOn: $mix.prefs.ui.tagGroups)
                    .settingsAnchor("tags.groups")
                Text("einzelner großbuchstabe = gruppe, die folgenden tags gehören dazu und tragen ihre farbe. wort nur in großbuchstaben (BASIS) = rolle. tags ▾ zeigt eine spalte je gruppe. je gruppe: name, farbe aus der wellenform oder eigene farbe").settingsHint()
                if mix.prefs.ui.tagGroups {
                    ForEach(groupMarkers, id: \.self) { g in
                        LabeledContent("Gruppe \(g)") {
                            HStack {
                                TextField("", text: Binding(get: { mix.prefs.ui.tagGroupNames[g] ?? "" },
                                                            set: { mix.prefs.ui.tagGroupNames[g] = $0.isEmpty ? nil : $0 }))
                                    .settingsField().frame(width: 120)
                                Picker("", selection: Binding(get: { mix.prefs.ui.tagGroupWave[g] ?? "aus" },
                                                              set: { mix.prefs.ui.tagGroupWave[g] = $0; if $0 != "aus" { mix.prefs.ui.tagColors[g] = nil } })) {
                                    ForEach(TagColors.waveSources, id: \.id) { Text(LocalizedStringKey($0.name)).tag($0.id) }
                                }
                                .labelsHidden().frame(width: 190)
                                // eigene Farbe (Farbe des Markers), gilt bei „eigene Farbe“
                                ColorPicker("", selection: Binding(get: { TagColors.color(g, group: g, mix.prefs.ui) },
                                                                   set: { mix.prefs.ui.tagColors[g] = TagColors.hex(of: $0); mix.prefs.ui.tagGroupWave[g] = "aus" }),
                                            supportsOpacity: false).labelsHidden()
                            }
                        }
                    }
                }
            }
            }
            if colors {
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
}
