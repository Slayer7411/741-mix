import SwiftUI

/// ⌘, -> BROWSER, Abschnitt „Zeilen & Felder“: Zeilen ein-/zweizeilig, Detailleiste, Werte kürzen, Teile der Sammelspalte
struct BrowserRowsSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        Section("Zeilen & Felder") {
            Picker("Zeilen", selection: $mix.prefs.ui.browserRows) {
                ForEach(BrowserRows.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .settingsAnchor("browser.rows")
            Picker("Detailleiste unter der Liste", selection: $mix.prefs.ui.detailBar) {
                ForEach(DetailBarMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .settingsAnchor("browser.detailbar")
            Toggle("Werte kürzen", isOn: $mix.prefs.ui.shortValues)
                .settingsAnchor("browser.shortvalues")
            Text("gilt für bereiche ohne eigene wahl; je bereich umschaltbar mit ≡ / ☰ und ▭ im kopf. werte kürzen: version im titel als kürzel (OM, EXT, RMX …), titel und artist in der mitte gekürzt, bpm ganzzahlig, datum kurz. sortierung und suche nutzen die vollen werte.")
                .settingsHint()
            TrackPartsEditor(raw: $mix.prefs.ui.trackParts)
                .settingsAnchor("browser.trackparts")
        }
    }
}

/// Teile der Sammelspalte „Track“ in Reihenfolge, ▲▼ verschiebt, ✕ nimmt heraus, unten wieder hinzufügen und Vorlagen
struct TrackPartsEditor: View {
    @Binding var raw: [String]

    var body: some View {
        let parts = TrackParts.normalized(raw)
        VStack(alignment: .leading, spacing: 3) {
            Text("SPALTE TRACK (ZWEIZEILIG)").font(Theme.label(10, .bold)).foregroundStyle(Theme.bone.opacity(0.8))
            ForEach(Array(parts.enumerated()), id: \.element) { i, p in
                HStack(spacing: 6) {
                    Text(p.name).font(Theme.mono(11)).foregroundStyle(p == .lineBreak ? Theme.muted : Theme.bone)
                        .frame(width: 170, alignment: .leading)
                    Button("▲") { set(TrackParts.moved(parts, p, by: -1)) }.disabled(i == 0)
                    Button("▼") { set(TrackParts.moved(parts, p, by: 1)) }.disabled(i == parts.count - 1)
                    if p != .lineBreak {
                        Button("✕") { set(parts.filter { $0 != p }) }.disabled(parts.count <= 2)
                    }
                }
                .buttonStyle(.borderless)
                .font(Theme.mono(11))
            }
            let missing = TrackPart.allCases.filter { !parts.contains($0) }
            if !missing.isEmpty {
                HStack(spacing: 4) {
                    Text("+").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    ForEach(missing) { p in DeckButton(title: p.name.uppercased(), verbatim: true) { set(parts + [p]) } }
                }
            }
            HStack(spacing: 4) {
                Text("VORLAGE").font(Theme.label(10, .bold)).foregroundStyle(Theme.muted)
                ForEach(TrackParts.presets, id: \.0) { name, preset in
                    DeckButton(title: name.uppercased(), active: parts == preset, verbatim: true) { set(preset) }
                }
            }
            Text("zeile 1 bis „— Zeile 2 —“, der rest darunter. vorlage kommentar zuerst: kommentar · titel, darunter artist · tags. schmale spalten (☁✓, bpm, key, time …) bleiben eigene spalten.")
                .settingsHint()
        }
    }

    private func set(_ p: [TrackPart]) { raw = p.map(\.rawValue) }
}
