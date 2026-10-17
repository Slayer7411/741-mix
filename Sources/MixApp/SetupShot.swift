import AppKit
import SwiftUI
import MixEngine
import MixCore

/// Selbsttest-Bild der Einrichtung (MIX741_SELFTEST=1 MIX741_SHOT=setup:<png>, MIX741_SHOT_STEP=collection|music|audio|
/// network|done): ein Schritt offscreen gerendert, kein Fenster, kein Audio. Endet mit exit(0).
@MainActor
enum SetupShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let arg = ProcessInfo.processInfo.environment["MIX741_SHOT"], arg.hasPrefix("setup:") else { return }
        let path = String(arg.dropFirst("setup:".count))
        NSApplication.shared.setActivationPolicy(.prohibited)

        // wie SettingsShot: nur die eingebauten Lautsprecher, gespeicherte Einstellungen bleiben unberührt
        let d = E2E.defaults
        let keys = ["mixerMode", "deviceUID", "internalPair", "deckPairs", "sampleRate", "bufferSize", "prefs.v1"]
        let saved = keys.map { ($0, d.object(forKey: $0)) }
        let restore = { for (k, v) in saved { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        d.setVolatileDomain(["deviceUID": "BuiltInSpeakerDevice", "mixerMode": "Intern", "sampleRate": 0.0, "bufferSize": 0],
                            forName: UserDefaults.argumentDomain)
        let mix = MixModel()
        mix.engine.setMasterVolume(0)
        d.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        restore()
        let store = LibraryStore()
        store.load()
        let status = ControllerStatus()
        let browser = BrowserState()
        let deadline = Date().addingTimeInterval(20)
        while store.tracks.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }

        let step = ProcessInfo.processInfo.environment["MIX741_SHOT_STEP"] ?? "collection"
        SetupFlow.shared.attach(mix)
        SetupFlow.shared.step = SetupFlow.Step(rawValue: step) ?? .collection
        let view = AnyView(SetupFlowView().environment(mix).environment(store).environment(status).environment(browser)
            .frame(width: 560))
        SettingsShot.render(view, to: URL(fileURLWithPath: path), fitHeight: true)
        print("[shot] Einrichtung \(step) -> \(path)")
        exit(0)
    }
}
