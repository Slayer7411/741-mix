import AppKit
import Foundation
import Observation
import SwiftUI
import MixCore

/// Eingebaute Wellenform-Presets: die Varianten A…K auf der RGB-Palette, dazu die Paletten 741 Knochen, Orange,
/// Blau/Weiß, Klassisch mit den Standardwerten. Umstellung alter Einstellungen (Variante, Farben, Höhen-Betonung)
enum WavePresets {
    /// Varianten gegenüber A (alte Auswahl ⌘, -> Variante, Index = `ui.blendPreset`)
    static let variants: [(id: String, name: String, apply: (inout BlendPaint.Palette) -> Void)] = [
        ("blend.a", "A · Standard", { _ in }),
        ("blend.b", "B · Mitten +", { $0.gain.g = 0.85 }),
        ("blend.c", "C · Mitten ++, Höhen +", { $0.gain.g = 1.2; $0.gain.b *= 1.3 }),
        ("blend.d", "D · klare Stapel", { $0.base = 0.15 }),
        ("blend.e", "E · nur Stapel", { $0.base = 0; $0.gain.g = 0.75 }),
        ("blend.f", "F · harte Kanten", { $0.fade = 0.05; $0.base = 0.25; $0.gain.g = 0.75 }),
        ("blend.g", "G · leise Bänder höher", { $0.stackCurve = 0.45; $0.gain.g = 0.75 }),
        ("blend.h", "H · nach Pegel", { $0.stackCurve = 0.85; $0.base = 0.25; $0.gain.g = 0.85 }),
        ("blend.i", "I · ohne Orange", { $0.warmth = 0; $0.gain.g = 0.8 }),
        ("blend.j", "J · Energie-Mischung, ohne Stapel", { $0.base = 1; $0.saturation = 1.2; $0.gain.g = 0.8 }),
        ("blend.k", "K · weich", { $0.saturation = 1.0; $0.base = 0.5; $0.gain.g = 0.8 }),
    ]

    /// Palette der drei Farben (gehaltene Höhen halb zu Weiß, gehaltene Tiefen halb zu Orange); RGB = Bandanteile direkt
    static func basePalette(_ p: WaveformPalette) -> BlendPaint.Palette {
        guard p != .rgb else { return .rgb }
        let c = RenderedWaveform.Colors.of(p)
        let f = { (v: RenderedWaveform.RGB) in (r: Float(v.r), g: Float(v.g), b: Float(v.b)) }
        return BlendPaint.Palette(low: f(c.low), mid: f(c.mid), high: f(c.high))
    }

    static let paletteIDs: [WaveformPalette: String] = [.bone: "palette.bone", .orange: "palette.orange", .blue: "palette.blue", .classic: "palette.classic"]

    static let builtIn: [WavePreset] = variants.map { v in
        var p = BlendPaint.Palette.rgb
        v.apply(&p)
        return WavePreset(id: v.id, name: v.name, builtIn: true, look: .init(p))
    } + [WaveformPalette.bone, .orange, .blue, .classic].map {
        WavePreset(id: paletteIDs[$0]!, name: $0.rawValue, builtIn: true, look: .init(basePalette($0)))
    }

    static var standard: WavePreset { builtIn[0] }

    /// angezeigter Name (eingebaute übersetzt)
    static func title(_ p: WavePreset) -> String { p.builtIn ? String(localized: String.LocalizationValue(p.name)) : p.name }

    /// alte Auswahl -> eingebautes Preset oder eigenes (Farben + Variante + Höhen-Betonung)
    static func migrate(palette: WaveformPalette, highBoost: Double, variant: Int) -> (id: String, created: WavePreset?) {
        let v = variants[max(0, min(variants.count - 1, variant))]
        if highBoost == 1 {
            if palette == .rgb { return (v.id, nil) }
            if variant <= 0, let id = paletteIDs[palette] { return (id, nil) }
        }
        var p = basePalette(palette)
        v.apply(&p)
        let name = "\(v.name) · \(palette.rawValue)" + (highBoost == 1 ? "" : String(format: " · %.2f", highBoost))
        let base = palette == .rgb ? v.id : (variant <= 0 ? paletteIDs[palette] : nil)
        return ("", WavePreset(name: name, base: base, look: .init(p, highBoost: Float(highBoost))))
    }
}

/// eingebaute + eigene Presets (`wave-presets.json` im MINOS-741-Ordner, Selbsttest: Temp-Ordner), atomar geschrieben
@MainActor @Observable
final class WavePresetStore {
    private(set) var list: WavePresetList
    @ObservationIgnored let url: URL
    @ObservationIgnored private var written: Data?
    nonisolated private static let queue = DispatchQueue(label: "minos741.wave-presets", qos: .utility)

    static var defaultURL: URL {
        Session.isSelfTest ? selfTestDir.appendingPathComponent("wave-presets.json") : HistoryStore.baseDir.appendingPathComponent("wave-presets.json")
    }
    static let selfTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("minos741-selftest-wave-\(getpid())", isDirectory: true)

    init(url: URL? = nil) {
        let url = url ?? Self.defaultURL
        self.url = url
        var custom: [WavePreset] = []
        if let d = try? Data(contentsOf: url) {
            if let c = try? WavePresetList.decodeCustom(d) {
                custom = c
                written = d
            } else {
                let aside = url.deletingLastPathComponent().appendingPathComponent("wave-presets-unlesbar-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.moveItem(at: url, to: aside)
                let note = String(localized: "wave-presets.json nicht lesbar – beiseitegelegt als \(aside.lastPathComponent)")
                DispatchQueue.main.async { StatusCenter.post(.warning, note, detail: aside.path, key: "wave-presets") }
            }
        }
        list = WavePresetList(builtIn: WavePresets.builtIn, custom: custom)
    }

    var all: [WavePreset] { list.all }
    func resolved(_ id: String) -> WavePreset { list.resolved(id) }

    private func change(_ f: (inout WavePresetList) -> Void) {
        var l = list
        f(&l)
        guard l != list else { return }
        list = l
        save()
    }

    private func save() {
        guard let data = try? list.encoded(), data != written else { return }
        written = data
        let url = url
        Self.queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                DispatchQueue.main.async {
                    StatusCenter.post(.error, String(localized: "Wellenform-Presets nicht gespeichert: \(error.localizedDescription)"), detail: url.path, key: "wave-presets")
                }
            }
        }
    }

    /// wartet, bis alles geschrieben ist (Selbsttest, Beenden)
    nonisolated static func flush() { queue.sync {} }

    func add(_ p: WavePreset) -> String {
        var p = p
        p.builtIn = false
        p.name = list.uniqueName(p.name)
        change { $0.custom.append(p) }
        return p.id
    }

    func copy(_ id: String) -> String? {
        guard let src = list.preset(id) else { return nil }
        var new: String?
        change { new = $0.copy(id, suffix: "", name: "\(WavePresets.title(src)) \(String(localized: "Kopie"))") }
        return new
    }

    func rename(_ id: String, to name: String) { change { $0.rename(id, to: name) } }
    func delete(_ id: String) -> String? {
        var next: String?
        change { next = $0.delete(id) }
        return next
    }
    func reset(_ id: String) { change { $0.reset(id) } }
    func update(_ id: String, _ f: (inout WavePreset) -> Void) { change { $0.update(id, f) } }

    func removeSelfTestDir() { try? FileManager.default.removeItem(at: Self.selfTestDir) }
}

extension MixModel {
    /// aktives Preset (Stil 3-Band Mischung)
    var wavePreset: WavePreset { wavePresets.resolved(prefs.ui.wavePreset) }

    /// alte Einstellungen (Variante, Farben, Höhen-Betonung) einmalig auf ein Preset umstellen
    func migrateWavePreset() {
        guard prefs.ui.wavePreset.isEmpty else { return }
        let ui = prefs.ui
        let m = WavePresets.migrate(palette: ui.waveformPalette, highBoost: ui.waveformHighBoost, variant: ui.blendPreset)
        prefs.ui.wavePreset = m.created.map { wavePresets.add($0) } ?? m.id
    }

    func selectWavePreset(_ id: String) { prefs.ui.wavePreset = id }

    /// Neu: Kopie des aktiven Presets unter neuem Namen
    @discardableResult
    func newWavePreset(name: String? = nil) -> String {
        let cur = wavePreset
        let id = wavePresets.add(WavePreset(name: name ?? String(localized: "Eigenes Preset"), base: cur.builtIn ? cur.id : cur.base,
                                            analysis: cur.analysis, look: cur.look))
        prefs.ui.wavePreset = id
        return id
    }

    @discardableResult
    func copyWavePreset() -> String? {
        guard let id = wavePresets.copy(wavePreset.id) else { return nil }
        prefs.ui.wavePreset = id
        return id
    }

    func deleteWavePreset() {
        let cur = wavePreset
        guard !cur.builtIn, let next = wavePresets.delete(cur.id) else { return }
        prefs.ui.wavePreset = next
    }

    /// aktives Preset ändern; eingebaut -> zuerst eine eigene Kopie („<Name> Kopie“), die dann gewählt ist
    func editWavePreset(_ f: (inout WavePreset) -> Void) {
        var id = wavePreset.id
        if wavePreset.builtIn {
            var probe = wavePreset
            f(&probe)
            guard probe != wavePreset, let c = wavePresets.copy(id) else { return }
            id = c
            prefs.ui.wavePreset = id
        }
        wavePresets.update(id, f)
    }
}

// MARK: - Einstellungen

/// ⌘, -> ANZEIGE -> Wellenform, Stil 3-Band (Mischung): Preset wählen, anlegen, kopieren, umbenennen, löschen,
/// darunter seine Werte. Eingebaute Presets: die erste Änderung legt eine eigene Kopie an
struct WavePresetSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let cur = mix.wavePreset
        let store = mix.wavePresets
        LabeledContent("Preset") {
            Picker("Preset", selection: Binding(get: { cur.id }, set: { mix.selectWavePreset($0) })) {
                ForEach(store.list.builtIn) { Text(verbatim: WavePresets.title($0)).tag($0.id) }
                if !store.list.custom.isEmpty {
                    Divider()
                    ForEach(store.list.custom) { Text(verbatim: $0.name).tag($0.id) }
                }
            }
            .labelsHidden()
        }
        .background(UITestMark(name: "wave picker"))
        .settingsAnchor("display.wave.preset")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button("Neu") { askName(String(localized: "Neues Preset (aus dem aktuellen)"), String(localized: "Eigenes Preset")) { mix.newWavePreset(name: $0) } }
                Button("Kopieren") { mix.copyWavePreset() }.background(UITestMark(name: "wave copy"))
                Button("Umbenennen") { askName(String(localized: "Preset umbenennen"), cur.name) { store.rename(cur.id, to: $0) } }.disabled(cur.builtIn)
            }
            HStack(spacing: 4) {
                Button("Löschen") { mix.deleteWavePreset() }.disabled(cur.builtIn)
                Button("Zurücksetzen") { store.reset(cur.id) }
                    .disabled(cur.builtIn || cur.base.flatMap { store.list.preset($0) }.map { $0.analysis == cur.analysis && $0.look == cur.look } ?? true)
            }
        }
        .settingsControlColumn()
        (cur.builtIn
            ? Text("eingebaut: die erste änderung legt eine eigene kopie an („… kopie“) und wählt sie. eigene presets: wave-presets.json im minos-741-ordner.")
            : Text("eigenes preset. zurücksetzen = werte des eingebauten presets, aus dem es stammt."))
            .settingsHint()
    }

    private func askName(_ title: String, _ initial: String, _ done: (String) -> Void) {
        let a = NSAlert()
        a.messageText = title
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "OK"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { done(name) }
    }
}

/// Werte des aktiven Presets: Trennfrequenzen, Hüllkurven, Gewichte, Farben, Mischung
struct WavePresetFields: View {
    @Environment(MixModel.self) private var mix

    private func bind<T>(_ k: WritableKeyPath<WavePreset, T>) -> Binding<T> {
        Binding(get: { mix.wavePreset[keyPath: k] }, set: { v in mix.editWavePreset { $0[keyPath: k] = v } })
    }
    private func num(_ k: WritableKeyPath<WavePreset, Float>) -> Binding<Double> {
        Binding(get: { Double(mix.wavePreset[keyPath: k]) }, set: { v in mix.editWavePreset { $0[keyPath: k] = Float(v) } })
    }
    private func color(_ k: WritableKeyPath<WavePreset, WaveColor>) -> Binding<Color> {
        Binding(get: { let c = mix.wavePreset[keyPath: k]; return Color(.sRGB, red: Double(c.r), green: Double(c.g), blue: Double(c.b)) },
                set: { v in
                    guard let c = NSColor(v).usingColorSpace(.sRGB) else { return }
                    mix.editWavePreset { $0[keyPath: k] = WaveColor(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)) }
                })
    }

    var body: some View {
        let p = mix.wavePreset
        Group {
            freqRow("Trennfrequenz Tief", bind(\.analysis.low), 40...400).background(UITestMark(name: "wave low"))
                .settingsAnchor("display.wave.low")
            LabeledContent("Trennfrequenz Mitte") {
                HStack(spacing: 10) {
                    Toggle("auto", isOn: Binding(get: { p.analysis.mid == nil },
                                                  set: { on in mix.editWavePreset { $0.analysis.mid = on ? nil : $0.analysis.midHz.rounded() } }))
                        .toggleStyle(.checkbox).fixedSize()
                    LogSlider(value: Binding(get: { p.analysis.midHz }, set: { v in mix.editWavePreset { $0.analysis.mid = v.rounded() } }), range: 200...2000)
                        .disabled(p.analysis.mid == nil)
                    hz(p.analysis.midHz)
                }
            }
            .settingsAnchor("display.wave.mid")
            freqRow("Trennfrequenz Hoch", bind(\.analysis.high), 1000...8000)
                .settingsAnchor("display.wave.high")
            Text("tief = tiefpass, mitte = bandpass, hoch = hochpass. auto = geometrisches mittel.")
                .settingsHint()
                .help("tief = tiefpass, mitte = bandpass, hoch = hochpass. auto = geometrisches mittel aus tief und hoch. änderungen rechnen geladene tracks im hintergrund neu.")
            msRow("Anstieg Tief", \.analysis.attackMs.low, 0.5...50).settingsAnchor("display.wave.attack.low")
            msRow("Abfall Tief", \.analysis.releaseMs.low, 5...400).settingsAnchor("display.wave.release.low")
            msRow("Anstieg Mitte", \.analysis.attackMs.mid, 0.5...50).settingsAnchor("display.wave.attack.mid")
            msRow("Abfall Mitte", \.analysis.releaseMs.mid, 5...400).settingsAnchor("display.wave.release.mid")
            msRow("Anstieg Hoch", \.analysis.attackMs.high, 0.5...50).settingsAnchor("display.wave.attack.high")
            msRow("Abfall Hoch", \.analysis.releaseMs.high, 5...400).settingsAnchor("display.wave.release.high")
            row("Analyse-Gewicht Tief", num(\.analysis.weights.low), 0...3)
                .settingsAnchor("display.wave.weight.low")
            row("Analyse-Gewicht Mitte", num(\.analysis.weights.mid), 0...3)
                .settingsAnchor("display.wave.weight.mid")
            row("Analyse-Gewicht Hoch", num(\.analysis.weights.high), 0...3)
                .settingsAnchor("display.wave.weight.high")
        }
        Group {
            Toggle("Bandanteile direkt als Rot / Grün / Blau", isOn: bind(\.look.direct))
                .settingsAnchor("display.wave.direct")
            if !p.look.direct {
                colorRow("Farbe Tief", \.look.low)
                    .settingsAnchor("display.wave.color.low")
                colorRow("Farbe Mitte", \.look.mid)
                    .settingsAnchor("display.wave.color.mid")
                colorRow("Farbe Hoch", \.look.high)
                    .settingsAnchor("display.wave.color.high")
            }
            colorRow("Gehaltene Höhen (offene Hats)", \.look.highOpen)
                .settingsAnchor("display.wave.color.highopen")
            colorRow("Gehaltene Tiefen (Bassline)", \.look.lowWarm)
                .settingsAnchor("display.wave.color.lowwarm")
            row("Lautstärke Tief", num(\.look.gain.low), 0...3)
                .settingsAnchor("display.wave.gain.low")
            row("Lautstärke Mitte", num(\.look.gain.mid), 0...3)
                .settingsAnchor("display.wave.gain.mid")
            row("Lautstärke Hoch", num(\.look.gain.high), 0...4)
                .settingsAnchor("display.wave.gain.high")
            row("Höhen-Betonung", num(\.look.highBoost), 0...3, step: 0.25)
                .settingsAnchor("display.wave.preset.highboost")
        }
        Group {
            row("Energie-Anteil (base)", num(\.look.base), 0...1)
                .settingsAnchor("display.wave.base")
            row("Übergänge (fade)", num(\.look.fade), 0.01...0.5)
                .settingsAnchor("display.wave.fade")
            row("Stapel-Kurve", num(\.look.stackCurve), 0.2...1.5)
                .settingsAnchor("display.wave.stack")
            row("Sättigung (RGB)", num(\.look.saturation), 0.5...3)
                .settingsAnchor("display.wave.saturation")
            row("Orange gehaltener Tiefen", num(\.look.warmth), 0...1)
                .settingsAnchor("display.wave.warmth")
            row("Hellblau gehaltener Höhen", num(\.look.openness), 0...1)
                .settingsAnchor("display.wave.openness")
            Text("rot / grün / blau direkt: bandanteile als farbkanäle, sonst die drei farben.")
                .settingsHint()
                .help("rot / grün / blau direkt: bandanteile als farbkanäle (kick-anschlag rot, mitten grün, kurze höhen blau), sonst die drei farben. lautstärke = gewicht des bands in farbe und stapelhöhe. energie-anteil 1 = nur mischung, 0 = nur stapel (stärkstes band innen). sättigung nur bei rot / grün / blau direkt.")
        }
    }

    private func hz(_ v: Double) -> some View {
        Text(verbatim: v >= 1000 ? String(format: "%.2f kHz", v / 1000) : String(format: "%.0f Hz", v))
            .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.bone)
            .frame(width: SettingsMetrics.readoutWidth, alignment: .trailing)
    }

    private func freqRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            HStack(spacing: 10) {
                LogSlider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 >= 1000 ? ($0 / 10).rounded() * 10 : $0.rounded()) }), range: range)
                hz(value.wrappedValue)
            }
        }
    }

    private func msRow(_ title: String, _ k: WritableKeyPath<WavePreset, Double>, _ range: ClosedRange<Double>) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            HStack(spacing: 10) {
                LogSlider(value: Binding(get: { mix.wavePreset[keyPath: k] }, set: { v in mix.editWavePreset { $0[keyPath: k] = (v * 10).rounded() / 10 } }), range: range)
                Text(verbatim: String(format: "%.1f ms", mix.wavePreset[keyPath: k]))
                    .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.bone)
                    .frame(width: SettingsMetrics.readoutWidth, alignment: .trailing)
            }
        }
    }

    private func row(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double = 0.01) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            HStack(spacing: 10) {
                Slider(value: Binding(get: { value.wrappedValue },
                                      set: { v in value.wrappedValue = min(range.upperBound, max(range.lowerBound, step * (v / step).rounded())) }),
                       in: range)
                Text(verbatim: String(format: "%.2f", value.wrappedValue))
                    .font(Theme.mono(11)).monospacedDigit().foregroundStyle(Theme.bone)
                    .frame(width: SettingsMetrics.readoutWidth, alignment: .trailing)
            }
        }
    }

    private func colorRow(_ title: String, _ k: WritableKeyPath<WavePreset, WaveColor>) -> some View {
        LabeledContent(LocalizedStringKey(title)) {
            ColorPicker("", selection: color(k), supportsOpacity: false).labelsHidden()
        }
    }
}

/// Regler mit logarithmischer Skala (Frequenzen, Zeiten)
struct LogSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        let lo = log(range.lowerBound), hi = log(range.upperBound)
        Slider(value: Binding(get: { (log(min(range.upperBound, max(range.lowerBound, value))) - lo) / (hi - lo) },
                              set: { value = exp(lo + $0 * (hi - lo)) }), in: 0...1)
    }
}
