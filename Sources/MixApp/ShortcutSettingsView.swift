import SwiftUI
import AppKit
import MixCore

/// Einstellungen -> Tastatur: jedes Kürzel der App neu belegen, entfernen, auf Standard zurück.
struct ShortcutSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        ScrollView { ShortcutTable(keys: $mix.prefs.keys) }
            .background(Theme.chitin)
    }
}

struct ShortcutTable: View {
    @Binding var keys: ShortcutMap
    @State private var recording: ShortcutID?
    @State private var monitor: Any?
    /// Favoriten-Modus: nur markierte Kürzel, ohne Kopf
    @Environment(\.settingsFilter) private var filter

    /// bleiben beim System (Beenden, Ausblenden, Minimieren, Vollbild)
    static let reserved: Set<KeyCombo> = [KeyCombo("q"), KeyCombo("h"), KeyCombo("h", [.option, .command]), KeyCombo("m"),
                                          KeyCombo("f", [.control, .command]), KeyCombo("q", [.control, .command])]

    init(keys: Binding<ShortcutMap>, recording: ShortcutID? = nil) {
        _keys = keys
        _recording = State(initialValue: recording)
    }

    var body: some View {
        let conflicts = keys.conflicts
        VStack(alignment: .leading, spacing: 0) {
            if filter == nil {
            HStack(alignment: .firstTextBaseline) {
                Text("TASTATUR").font(Theme.label(15, .bold)).foregroundStyle(Theme.bone)
                Spacer()
                DeckButton(title: "ALLE ZURÜCKSETZEN") { stop(); keys = ShortcutMap() }
                    .help("Alle Kürzel auf Standard")
                    .settingsAnchor("keys.reset")
            }
            Text("kürzel anklicken -> neue taste drücken · esc = abbrechen · ✕ = frei · ↺ = standard")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted).padding(.top, 4)
            Text("⌘Q, ⌘H, ⌘M und ⌃⌘F bleiben beim system · tasten ohne ⌘ / ⌥ / ⌃ wirken nicht im suchfeld")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            if !conflicts.isEmpty {
                Text("◆ \(conflicts.count) doppelt belegt -> es gilt die erste aktion in der liste")
                    .font(Theme.mono(10, .medium)).foregroundStyle(Theme.state).padding(.top, 4)
            }
            }
            ForEach(ShortcutGroup.allCases, id: \.self) { g in
                if ShortcutID.allCases.contains(where: { $0.group == g && visible($0) }) {
                    Text(g.title).font(Theme.label(11, .bold)).foregroundStyle(Theme.muted)
                        .padding(.top, 14).padding(.bottom, 4)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    ForEach(ShortcutID.allCases.filter { $0.group == g && visible($0) }) { a in
                        row(a).settingsAnchor(SettingsIndex.keyAnchor(a))
                        Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 1)
                    }
                }
            }
        }
        .padding(16)
        .onDisappear { stop() }
    }

    private func visible(_ a: ShortcutID) -> Bool { filter?.contains(SettingsIndex.keyAnchor(a)) ?? true }

    private func row(_ a: ShortcutID) -> some View {
        let c = keys.combo(a)
        let others = keys.conflicting(a)
        let rec = recording == a
        let red = rec || !others.isEmpty
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title).font(Theme.mono(11)).foregroundStyle(Theme.bone).lineLimit(1)
                if !others.isEmpty {
                    Text(String(localized: "auch: \(others.map(\.title).joined(separator: " · "))"))
                        .font(Theme.mono(9)).foregroundStyle(Theme.state).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { rec ? stop() : start(a) } label: {
                Text(rec ? String(localized: "Taste drücken …") : (c?.symbols ?? "—"))
                    .font(Theme.mono(12, .medium))
                    .foregroundStyle(red ? Theme.state : (c == nil ? Theme.muted : Theme.bone))
                    .frame(width: 140, height: 20)
                    .background(Rectangle().fill(Theme.void))
                    .overlay(Rectangle().stroke(red ? Theme.state : Theme.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Klicken und neue Taste drücken")
            Button { stop(); keys.set(a, nil) } label: {
                Text("✕").font(Theme.mono(11)).foregroundStyle(c == nil ? Theme.hairline : Theme.muted).frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(c == nil)
            .help("Kürzel entfernen")
            Button { stop(); keys.set(a, a.defaultCombo) } label: {
                Text("↺").font(Theme.mono(11)).foregroundStyle(keys.isDefault(a) ? Theme.hairline : Theme.bone).frame(width: 16)
            }
            .buttonStyle(.plain)
            .disabled(keys.isDefault(a))
            .help(String(localized: "Standard: \(a.defaultCombo?.symbols ?? "—")"))
        }
        .padding(.vertical, 4)
    }

    /// nächste Taste aufnehmen (lokaler Monitor, verbraucht die Taste; Kürzel lösen solange nichts aus)
    private func start(_ a: ShortcutID) {
        stop()
        recording = a
        KeyMonitor.recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            nonisolated(unsafe) let e = e   // Monitor läuft auf dem Hauptthread
            MainActor.assumeIsolated {
                let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
                if e.keyCode == 53, mods.isEmpty { stop(); return }   // esc = abbrechen
                if let c = KeyCombo(event: e), !Self.reserved.contains(c) {
                    keys.set(a, c)
                    stop()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = nil
        KeyMonitor.recording = false
    }
}

/// Selbsttest-Bild ohne Fenster: MIX741_SELFTEST=1 MIX741_SHOT=keys:<png> rendert den Tastatur-Tab offscreen
@MainActor
enum ShortcutShot {
    static func render(to path: String) -> Bool {
        var map = ShortcutMap()
        map.set(.sync, KeyCombo("l"))                      // Konflikt mit Loop (rot)
        map.set(.reloop, KeyCombo("r", [.option, .command]))
        let view = ShortcutTable(keys: .constant(map), recording: .cue)
            .frame(width: 600)
            .background(Theme.chitin)
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return false }
        print("[selftest] Tastatur-Tab: \(path) \(Int(host.bounds.width))×\(Int(host.bounds.height))")
        return true
    }
}
