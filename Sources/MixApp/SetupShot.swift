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

/// Absturz-Bild (MIX741_SELFTEST=1 MIX741_SHOT=crash:<png>): Absturz-Sheet mit einem erfundenen, bereinigten Bericht,
/// offscreen gerendert. Endet mit exit(0).
@MainActor
enum CrashShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let arg = ProcessInfo.processInfo.environment["MIX741_SHOT"], arg.hasPrefix("crash:") else { return }
        let path = String(arg.dropFirst("crash:".count))
        NSApplication.shared.setActivationPolicy(.prohibited)
        // erfundene Angaben: kein echter Nutzer, Rechner oder Pfad
        let names = CrashRedact.Names(home: "/Users/nutzer", user: "nutzer", fullName: "Max Mustermann", computer: "Testrechner")
        let header = #"{"app_name":"MINOS-741","app_version":"0.8.2","build_version":"4242","os_version":"macOS 26.0 (25A100)"}"#
        let body = #"""
        {"procPath":"/Users/nutzer/Applications/MINOS-741.app/Contents/MacOS/minos741","cpuType":"ARM-64","hardwareModel":"Mac15,7",
         "crashReporterKey":"6F3C2A1B-1111-2222-3333-444455556666","exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},
         "osVersion":{"train":"macOS 26.0","build":"25A100"},"faultingThread":0,
         "threads":[{"triggered":true,"frames":[{"imageOffset":4096,"symbol":"mixer_process","symbolLocation":12,"imageIndex":0},
         {"imageOffset":99,"imageIndex":1}]}],
         "usedImages":[{"path":"/Users/nutzer/x/minos741","name":"minos741"}]}
        """#
        let status = ["engine: Puffer 256 · 48 kHz", "deck A: Track geladen", "browser: Suche \"house\""]
        let text = CrashRedact.publicReport(ips: header + "\n" + body, status: status, names: names)
            ?? "MINOS-741 crash report (format not readable)\n"
        let title = CrashRedact.issueTitle(ips: header + "\n" + body, names: names)
        CrashPrompt.shared.present(CrashReports.Prompt(fileName: "MINOS-741_fake.ips", title: title, text: text, count: 1,
                                                       newest: Date()), mix: nil)
        let view = AnyView(CrashPromptView().frame(width: 560))
        SettingsShot.render(view, to: URL(fileURLWithPath: path), fitHeight: true)
        print("[shot] Absturz -> \(path)")
        exit(0)
    }
}
