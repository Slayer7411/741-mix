import AppKit
import SwiftUI
import MixCore
import MixEngine

/// Nur Selbsttest (MIX741_SHOT=fx:<ordner>): FX-Leiste mit Insert-Slots offscreen als PNG, ohne Audio.
/// topbar-2 / topbar-4: obere Leiste mit 2 bzw. 4 Units (Vorlage Gruppe, ein Slot, Rack mit Plugin, 6 Slots);
/// rack, picker, params: Rack-Popover, Effekt-Auswahl (Plugins vom Rechner, gesperrte mit Grund), Parameter eines Slots.
@MainActor
enum FXShot {
    static func runIfRequested() {
        guard Session.isSelfTest, let spec = ProcessInfo.processInfo.environment["MIX741_SHOT"], spec.hasPrefix("fx:") else { return }
        let dir = URL(fileURLWithPath: String(spec.dropFirst(3)))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let mix = MixModel()
        let core = mix.core
        core.engine.setMasterVolume(0)
        core.engine.stop()
        var ui = mix.prefs.ui
        ui.zoom = 1
        ui.showFXUnits = true
        mix.prefs.ui = ui
        ZoomControl.apply(1)

        Task { @MainActor in
            core.updateFX(0) { $0.slots = FXTemplate.group.slots; $0.slots[0].on = true; $0.slots[0].params["cutoff"] = 0.3; $0.slots[1].on = true }
            core.setSlots(1, [FXSlot(id: "DELAY", on: true, params: ["feedback": 0.6, "rate": 0.6])])
            core.setSlots(2, [FXSlot(id: "REVERB", on: true, mix: 0.7), FXSlot(id: "aufx:mrev:appl", on: true), FXSlot(id: "PHASER")])
            core.setSlots(3, [FXSlot(id: "FILTER"), FXSlot(id: "DELAY", on: true, mix: 0.4), FXSlot(id: "REVERB"), FXSlot(id: "GATER"),
                              FXSlot(id: "aufx:dely:appl"), FXSlot(id: "PHASER", on: true)])
            for _ in 0..<300 where core.pluginInstance(2, slot: 1) == nil || core.pluginInstance(3, slot: 4) == nil {
                try? await Task.sleep(for: .milliseconds(20))
            }
            _ = mix.pluginChoices(refresh: true)
            mix.pull()
            for n in [2, 4] {
                mix.prefs.ui.fxUnitCount = n
                mix.pull()
                render(TopBar().environment(mix), width: n == 2 ? 1440 : 1920, dir.appendingPathComponent("topbar-\(n).png"))
            }
            for u in 0..<4 { render(FXUnitView(u: u).environment(mix), width: nil, dir.appendingPathComponent("unit-\(u + 1).png")) }
            render(MasterClockPanel().environment(mix), width: nil, dir.appendingPathComponent("clock.png"))
            render(RackView(b: 2).environment(mix), width: nil, dir.appendingPathComponent("rack.png"))
            render(EffectPicker(b: 2, replacing: nil).environment(mix), width: nil, dir.appendingPathComponent("picker.png"))
            render(EffectPicker(b: 1, replacing: 0, query: "oril").environment(mix), width: nil, dir.appendingPathComponent("picker-intel.png"))
            render(SlotParamsView(b: 1, k: 0).environment(mix), width: nil, dir.appendingPathComponent("params.png"))
            log("PNG \(dir.path)")
            exit(0)
        }
        NSApplication.shared.run()
    }

    /// Ansicht offscreen zeichnen; ohne Breite = ideale Größe
    private static func render(_ v: some View, width: CGFloat?, _ url: URL) {
        let root = v
            .frame(width: width)
            .fixedSize(horizontal: width == nil, vertical: true)
            .padding(6)
            .background(Theme.background)
            .foregroundStyle(Theme.bone)
            .tint(Theme.state)
            .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        log("\(url.lastPathComponent): \(Int(host.bounds.width))×\(Int(host.bounds.height))")
    }

    static func log(_ s: String) {
        print("[shot] \(s)")
        fflush(stdout)
    }
}
