import AppKit
import SwiftUI
import MixCore
import MixMedia

/// Bezeichnungen der Ausgabe-Einstellungen (Fenster EXPORT, ⌘, -> AUDIO-EDIT / Vorbereiten)
extension ExportContainer {
    var label: String {
        switch self {
        case .source: String(localized: "wie Quelle")
        case .wav: "WAV"
        case .aiff: "AIFF"
        case .alac: String(localized: "Apple Lossless (.m4a)")
        case .aac: String(localized: "AAC (.m4a)")
        }
    }
}

extension ExportBits {
    var label: String {
        switch self {
        case .source: String(localized: "wie Quelle")
        case .b16: String(localized: "16 Bit")
        case .b24: String(localized: "24 Bit")
        case .float32: String(localized: "32 Bit Float (nur WAV)")
        }
    }
}

extension ExportOptions {
    /// 0 = wie Quelle, sonst „44,1 kHz“ usw.
    static func rateLabel(_ hz: Int) -> String {
        guard hz > 0 else { return String(localized: "wie Quelle") }
        return hz % 1000 == 0 ? "\(hz / 1000) kHz" : String(format: "%.1f kHz", Double(hz) / 1000).replacingOccurrences(of: ".", with: ",")
    }

    /// Kurzform des Ergebnisses für eine Quelle, z. B. „aiff · 16 Bit · 48 kHz · dither“
    func summary(source url: URL, wavRule: Bool) -> String {
        let f = AudioCutWriter.format(matching: url, options: self, wavRule: wavRule)
        var parts = [f.ext]
        switch f.container {
        case .aac: parts.append("AAC \(f.kbps) kbit/s")
        default: parts.append(f.float ? String(localized: "32 Bit Float") : "\(f.bitDepth) Bit")
        }
        if let r = f.rate { parts.append(ExportOptions.rateLabel(Int(r))) }
        if f.dither { parts.append("TPDF") }
        return parts.joined(separator: " · ")
    }
}

/// Cover-Auswahl im Fenster
private enum CoverKind: Hashable {
    case keep, none, image
}

/// EXPORT vor RENDER (AUDIO-EDIT): Format, Bit, Abtastrate, Dither, Dateiname und Metadaten der neuen Datei. Die
/// Felder sind mit der Quelle gefüllt; nur geänderte Felder überschreiben, was der Schnitt abgeleitet hat
struct ExportSheet: View {
    @Environment(MixModel.self) private var mix
    @Environment(\.dismiss) private var dismiss
    let d: Int
    /// Quelle (Track der Edit-Sitzung): Vorgabe der Felder
    let base: Track
    @State private var options: ExportOptions
    @State private var tags: ExportTags
    @State private var yearText: String
    @State private var bpmText: String
    @State private var coverName: String?
    @State private var remember = false

    init(d: Int, base: Track, options: ExportOptions) {
        self.d = d
        self.base = base
        _options = State(initialValue: options)
        let t = ExportTags(track: base)
        _tags = State(initialValue: t)
        _yearText = State(initialValue: t.year.map(String.init) ?? "")
        _bpmText = State(initialValue: t.bpm.map { String(format: "%.2f", $0) } ?? "")
    }

    private var coverKind: Binding<CoverKind> {
        Binding(get: {
            switch tags.cover {
            case .keep: .keep
            case .none: .none
            case .image: .image
            }
        }, set: { k in
            switch k {
            case .keep: tags.cover = .keep; coverName = nil
            case .none: tags.cover = .none; coverName = nil
            case .image: chooseCover()
            }
        })
    }

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.message = String(localized: "Cover für die neue Datei wählen")
        guard panel.runModal() == .OK, let u = panel.url, let data = try? Data(contentsOf: u) else { return }
        tags.cover = .image(data)
        coverName = u.lastPathComponent
    }

    private func render() {
        var e = tags
        e.year = Int(yearText.trimmingCharacters(in: .whitespaces))
        e.bpm = Double(bpmText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        if remember { mix.prefs.ui.export = options }
        mix.editRenderFile(d, sheet: ExportEdit(options: options, edited: e, prefill: ExportTags(track: base)))
        dismiss()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: "EXPORT").font(Theme.label(12.z, .bold))
            Form {
                Section(String(localized: "Format")) {
                    Picker(String(localized: "Format"), selection: $options.container) {
                        ForEach(ExportContainer.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(String(localized: "Bit"), selection: $options.bits) {
                        ForEach(ExportBits.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker(String(localized: "Abtastrate"), selection: $options.rate) {
                        ForEach(ExportOptions.rates, id: \.self) { Text(ExportOptions.rateLabel($0)).tag($0) }
                    }
                    if options.container == .aac {
                        Picker(String(localized: "AAC-Bitrate"), selection: $options.aacKbps) {
                            ForEach(ExportOptions.aacRates, id: \.self) { Text("\($0) kbit/s").tag($0) }
                        }
                    }
                    Toggle(String(localized: "Dither (TPDF) beim Schritt auf 16 Bit"), isOn: $options.dither)
                    Text(options.summary(source: URL(fileURLWithPath: base.path), wavRule: false))
                        .font(Theme.mono(10)).foregroundStyle(.secondary)
                }
                Section(String(localized: "Metadaten")) {
                    TextField(String(localized: "Titel"), text: $tags.title)
                    TextField(String(localized: "Künstler"), text: $tags.artist)
                    TextField(String(localized: "Album"), text: $tags.album)
                    TextField(String(localized: "Remixer"), text: $tags.remixer)
                    TextField(String(localized: "Label"), text: $tags.label)
                    TextField(String(localized: "Genre"), text: $tags.genre)
                    TextField(String(localized: "Jahr"), text: $yearText)
                    TextField(String(localized: "BPM"), text: $bpmText)
                    TextField(String(localized: "Tonart (Open Key, z. B. 8a)"), text: $tags.key)
                    TextField(String(localized: "Kommentar"), text: $tags.comment)
                    HStack {
                        Picker(String(localized: "Cover"), selection: coverKind) {
                            Text(String(localized: "Quelle übernehmen")).tag(CoverKind.keep)
                            Text(String(localized: "keins")).tag(CoverKind.none)
                            Text(coverName ?? String(localized: "Bild …")).tag(CoverKind.image)
                        }
                    }
                }
                Section(String(localized: "Datei")) {
                    TextField(String(localized: "Muster: {name} {tag} (leer = wie bisher)"), text: $options.pattern)
                    Toggle(String(localized: "als Standard merken"), isOn: $remember)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button(String(localized: "abbrechen")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("RENDER") { render() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
    }
}
