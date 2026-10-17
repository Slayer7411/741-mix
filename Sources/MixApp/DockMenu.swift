import AppKit
import MixEngine

/// Dock-Menü: LIVE an/aus, alle Decks stoppen, Einstellungen, Einrichtung. Die Aktionen laufen über dieselben Wege
/// wie die Menüs (MixModel, Einstellungsfenster, Einrichtungs-Sheet)
@MainActor
final class DockMenu: NSObject {
    /// Gesetzt beim Start (MixApp.startControllers); ohne Modell bleibt das Menü leer
    weak var mix: MixModel?

    func menu() -> NSMenu? {
        guard let mix else { return nil }
        let m = NSMenu()
        let live = NSMenuItem(title: "LIVE", action: #selector(toggleLive), keyEquivalent: "")
        live.target = self
        live.state = mix.live ? .on : .off
        m.addItem(live)
        let stop = NSMenuItem(title: String(localized: "Alle Decks stoppen"), action: #selector(stopAll), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = (0..<MixEngine.deckCount).contains { mix.deck($0).playing }
        m.addItem(stop)
        m.addItem(.separator())
        let settings = NSMenuItem(title: String(localized: "Einstellungen …"), action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(settings)
        let setup = NSMenuItem(title: String(localized: "Einrichtung …"), action: #selector(openSetup), keyEquivalent: "")
        setup.target = self
        m.addItem(setup)
        return m
    }

    @objc private func toggleLive() { mix?.setLive(!(mix?.live ?? false)) }

    @objc private func stopAll() {
        guard let mix else { return }
        for d in 0..<MixEngine.deckCount where mix.deck(d).playing { mix.togglePlay(d) }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openSetup() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showSetup, object: nil)
    }
}
