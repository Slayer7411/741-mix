import AppKit
import SwiftUI
import MixEngine

/// Plugin-Kette einer FX-Unit oder des Master-Busses (b = MixController.masterBus): Plätze in Reihe mit an/aus,
/// Plugin tauschen, ▲▼, Fenster, ✕; Plugin hinzufügen, gemerkte Ketten. Inhalt des Popovers
struct PluginChainView: View {
    @Environment(MixModel.self) private var mix
    let b: Int

    private var isMaster: Bool { b == MixController.masterBus }

    var body: some View {
        let chain = mix.chain(b)
        let list = mix.core.pluginList()
        let error = isMaster ? mix.masterPluginError : mix.fxUnits[b].pluginError
        let latency = mix.core.chainLatency(b)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(verbatim: "◆ " + (isMaster ? "MASTER" : "FX \(b + 1)") + " · ")
                    .font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
                    + Text("KETTE").font(Theme.label(11, .heavy)).foregroundStyle(Theme.bone)
                Spacer()
                if latency.total > 0 {
                    Text(verbatim: String(format: "%.1f ms", latency.total * 1000))
                        .font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .help("Latenz der Kette (Summe der Plugins, nicht ausgeglichen)")
                }
            }
            if chain.isEmpty {
                Text("leer – Plugin hinzufügen").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            ForEach(Array(chain.enumerated()), id: \.element.uid) { k, slot in
                row(k, slot, chain.count, list, latency.slots.indices.contains(k) ? latency.slots[k] : nil)
            }
            HStack(spacing: 6) {
                Menu {
                    ForEach(list) { p in Button(Self.title(p)) { mix.addPlugin(b, p.id) } }
                    Divider()
                    Button("Plugin-Liste neu einlesen") { _ = mix.core.pluginList(refresh: true) }
                } label: { Text("+ PLUGIN") }
                .menuStyle(.borderlessButton).fixedSize()
                .font(Theme.label(10, .bold))
                .disabled(chain.count >= MixEngine.chainSlots)
                .help("Plugin hinten an die Kette hängen (höchstens 4)")
                Menu {
                    let presets = mix.chainPresets
                    ForEach(presets, id: \.self) { n in Button(n) { mix.loadChainPreset(b, name: n) } }
                    if !presets.isEmpty { Divider() }
                    Button("Kette speichern …") { saveAsking() }.disabled(chain.isEmpty)
                    if !presets.isEmpty {
                        Menu("Löschen") { ForEach(presets, id: \.self) { n in Button(n) { mix.deleteChainPreset(n) } } }
                    }
                } label: { Text("KETTEN") }
                .menuStyle(.borderlessButton).fixedSize()
                .font(Theme.label(10, .bold))
                .help("Gemerkte Ketten laden oder die aktuelle merken (mit den Einstellungen der Plugins)")
            }
            if let error {
                Text(verbatim: "⚠︎ " + error).font(Theme.mono(10)).foregroundStyle(Theme.state).lineLimit(3)
            }
            if isMaster && !mix.masterFXActive {
                Text("extern: kein Summenpunkt – Master-Bus aus").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(10)
        .frame(width: 330)
        .background(Theme.chitin)
    }

    @ViewBuilder private func row(_ k: Int, _ slot: FXPluginSlot, _ count: Int, _ list: [PluginInfo], _ latency: Double?) -> some View {
        let info = list.first { $0.id == slot.id } ?? mix.core.pluginCatalog.info(slot.id)
        HStack(spacing: 4) {
            DeckButton(title: "ON", active: slot.on, color: Theme.state, width: 22) { mix.setPluginOn(b, slot: k, !slot.on) }
                .help("Platz an/aus (aus = durchreichen, Fahne klingt aus)")
            Text(verbatim: "\(k + 1)").font(Theme.mono(10, .bold)).foregroundStyle(Theme.muted)
            Menu {
                ForEach(list) { p in Button(Self.title(p)) { mix.replacePlugin(b, slot: k, p.id) } }
            } label: {
                Text(verbatim: info?.name ?? slot.id)
            }
            .menuStyle(.borderlessButton)
            .font(Theme.label(10, .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(Text(verbatim: (info.map { "\($0.name) · \($0.manufacturer)" } ?? slot.id)
                       + (latency.map { String(format: " · %.1f ms", $0 * 1000) } ?? "")) + Text(verbatim: " · ") + Text("Klick = anderes Plugin"))
            DeckButton(title: "▲", width: 12, verbatim: true) { mix.movePlugin(b, slot: k, by: -1) }
                .opacity(k > 0 ? 1 : 0.3).disabled(k == 0)
                .help("früher in der Kette")
            DeckButton(title: "▼", width: 12, verbatim: true) { mix.movePlugin(b, slot: k, by: 1) }
                .opacity(k < count - 1 ? 1 : 0.3).disabled(k >= count - 1)
                .help("später in der Kette")
            DeckButton(title: "EDIT", width: 26) { PluginWindow.show(unit: b, slot: k, core: mix.core) }
                .help("Plugin-Fenster öffnen")
            DeckButton(title: "✕", width: 12, verbatim: true) { mix.removePlugin(b, slot: k) }
                .help("aus der Kette nehmen")
        }
    }

    static func title(_ p: PluginInfo) -> String { p.name + " · " + p.manufacturer + (p.isVST3 ? "  VST3" : "") }

    private func saveAsking() {
        let a = NSAlert()
        a.messageText = String(localized: "Kette speichern")
        a.informativeText = String(localized: "Gibt es den Namen schon, wird diese Kette überschrieben.")
        let names = mix.chain(b).compactMap { s in mix.core.pluginCatalog.info(s.id)?.name ?? s.id.split(separator: ":").dropFirst().first.map(String.init) }
        let field = NSTextField(string: names.joined(separator: " > "))
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: String(localized: "Speichern"))
        a.addButton(withTitle: String(localized: "Abbrechen"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mix.saveChainPreset(b, name: name)
    }
}

/// Knopf mit der Kurzform der Kette ("AUDelay +1", "—"), öffnet die Kette als Popover
struct PluginChainButton: View {
    @Environment(MixModel.self) private var mix
    let b: Int
    var width: CGFloat = 70
    @State private var shown = false

    var body: some View {
        let chain = mix.chain(b)
        let error = b == MixController.masterBus ? mix.masterPluginError : mix.fxUnits[b].pluginError
        let first = chain.first.map { s in mix.core.pluginCatalog.info(s.id)?.name ?? s.id }
        let label = (error != nil ? "⚠︎ " : "") + (first.map { String($0.prefix(10)) } ?? "—") + (chain.count > 1 ? " +\(chain.count - 1)" : "")
        Button { shown.toggle() } label: {
            Text(verbatim: label)
                .font(Theme.label(10.z, .bold))
                .lineLimit(1)
                .foregroundStyle(Theme.bone)
                .frame(minWidth: width.z, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(error ?? String(localized: "Plugin-Kette: bis zu 4 Plugins in Reihe (Audio Unit oder VST3)"))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            PluginChainView(b: b).environment(mix)
        }
    }
}

/// Master-Bus im Mixer: FX an/aus, D/W, Kette. Extern (jedes Deck auf eigenem Paar) ohne Summenpunkt: aus, mit Hinweis
struct MasterFXStrip: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let m = mix.masterFX, active = mix.masterFXActive
        VStack(alignment: .leading, spacing: 3.z) {
            fx(m, active)
            // Aufnahme (Master oder Eingang vom Pult, ⌘, -> AUDIO); auch extern aktiv
            HStack(spacing: 4.z) {
                RecordButton(compact: true)
                RecordMeter(width: 40)
            }
        }
    }

    private func fx(_ m: MasterFXState, _ active: Bool) -> some View {
        HStack(spacing: 4.z) {
            Text("MASTER").font(Theme.label(9.z, .heavy)).foregroundStyle(m.on && active ? Theme.state : Theme.muted)
            DeckButton(title: "FX", active: m.on, color: Theme.state, width: 20) { mix.toggleMasterFX() }
                .help(active ? Text("Master-Bus an/aus: Plugin-Kette nach der Summe der Decks, vor MAIN")
                             : Text("Extern: kein Summenpunkt – der Master-Bus wirkt nur im internen Mixer"))
            Knob(value: Binding(get: { mix.masterFX.dryWet }, set: { mix.setMasterFX(dryWet: $0) }),
                 range: 0...1, defaultValue: 1, label: "D/W", color: Theme.state, size: 18)
            PluginChainButton(b: MixController.masterBus, width: 54)
            if !active { Text("EXTERN AUS").font(Theme.label(8.z, .bold)).foregroundStyle(Theme.muted) }
        }
        .opacity(active ? 1 : 0.55)
    }
}
