import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import CoreAudioKit
import SwiftUI
import MixEngine

/// Fenster mit der Oberfläche eines Plugins (eine FX-Unit, Instanz des ersten Decks; Änderungen gehen live an alle Decks).
/// AU: AUv3-View-Controller, eigene Cocoa-Ansicht (v2), sonst die generische Ansicht.
/// VST3: eigene Ansicht (IPlugView in einer NSView), sonst Schieberegler je Parameter.
@MainActor
final class PluginWindow: NSObject, NSWindowDelegate {
    private static var open: [Int: PluginWindow] = [:]

    private let unit: Int
    private let inst: PluginInstance
    private let core: MixController
    private let window: NSWindow
    private var viewController: NSViewController?
    private var hasView = false
    /// VST3: Ansicht des Plugins hängt in diesem Container
    private var vst3Container: NSView?
    private var resizingFromPlugin = false

    static func show(unit u: Int, core: MixController) {
        if let w = open[u] { w.window.makeKeyAndOrderFront(nil); return }
        guard let inst = core.beginPluginEdit(u) else { NSSound.beep(); return }
        let w = PluginWindow(unit: u, inst: inst, core: core)
        open[u] = w
        w.loadView()
        w.window.center()
        w.window.makeKeyAndOrderFront(nil)
    }

    static func close(_ u: Int) { open[u]?.window.close() }

    private init(unit: Int, inst: PluginInstance, core: MixController) {
        self.unit = unit
        self.inst = inst
        self.core = core
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "◆ PLUGIN · \(inst.info.name) · FX \(unit + 1)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        if vst3Container != nil { inst.closeEditor(); vst3Container = nil }
        core.endPluginEdit(unit, inst)
        Self.open[unit] = nil
    }

    /// Fenster gezogen (nur VST3 mit veränderbarer Ansicht): Größe an das Plugin, es darf sie anpassen
    func windowDidEndLiveResize(_ notification: Notification) {
        guard let c = vst3Container, !resizingFromPlugin, let size = window.contentView?.frame.size,
              let got = inst.setEditorSize(Int(size.width), Int(size.height)) else { return }
        c.frame = NSRect(x: 0, y: 0, width: got.width, height: got.height)
        if Int(size.width) != got.width || Int(size.height) != got.height {
            window.setContentSize(NSSize(width: got.width, height: got.height))
        }
    }

    private func loadView() {
        if inst.isVST3 { loadVST3View(); return }
        guard let au = inst.audioUnit else { return }
        // isoliert: Ansicht nur aus dem Dienst (View-Controller) oder generisch – nie den Ansichts-Code eines v2-Plugins
        // in den Prozess laden. Im Prozess: Absturz-Markierung um das Laden der Ansicht
        if isV3(au) || inst.outOfProcess {
            // AUv3: der View-Controller kommt asynchron; bleibt er aus, nach 3 s die generische Ansicht
            let block: @convention(block) (NSViewController?) -> Void = { [weak self] vc in
                DispatchQueue.main.async {
                    guard let self, !self.hasView else { return }
                    if let vc {
                        self.viewController = vc
                        let s = vc.preferredContentSize
                        self.install(vc.view, size: s.width > 10 && s.height > 10 ? s : nil)
                    } else {
                        self.install(self.genericView(), size: nil)
                    }
                }
            }
            // Wert der Eigenschaft ist der Block selbst (Objekt-Zeiger)
            let obj = block as AnyObject
            var ref: UnsafeRawPointer? = UnsafeRawPointer(Unmanaged.passUnretained(obj).toOpaque())
            let st = withExtendedLifetime(obj) {
                AudioUnitSetProperty(au, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0, &ref,
                                     UInt32(MemoryLayout<UnsafeRawPointer>.size))
            }
            if st == noErr {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, !self.hasView else { return }
                    self.install(self.genericView(), size: nil)
                }
                return
            }
        }
        if inst.outOfProcess { install(genericView(), size: nil); return }
        core.pluginCatalog.beginOpen(key: inst.info.id, name: inst.info.name)
        defer { core.pluginCatalog.endOpen() }
        install(cocoaView(au) ?? genericView(), size: nil)
    }

    private func install(_ view: NSView, size: NSSize?) {
        hasView = true
        let s = size ?? (view.frame.size.width > 10 ? view.frame.size : NSSize(width: 420, height: 300))
        window.contentView = view
        window.setContentSize(s)
    }

    private func isV3(_ au: AudioUnit) -> Bool {
        var d = AudioComponentDescription()
        guard AudioComponentGetDescription(AudioComponentInstanceGetComponent(au), &d) == noErr else { return false }
        return d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
    }

    /// eigene Cocoa-Ansicht eines v2-Plugins (Bundle + Fabrikklasse nach AUCocoaUIBase)
    private func cocoaView(_ au: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(au, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.load(as: AudioUnitCocoaViewInfo.self)
        let url = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let cls = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: url), let type = bundle.classNamed(cls) as? NSObject.Type,
              let factory = type.init() as? AUCocoaUIBase else { return nil }
        return factory.uiView(forAudioUnit: au, with: NSSize(width: 420, height: 300))
    }

    private func genericView() -> NSView {
        guard let au = inst.audioUnit else { return NSHostingView(rootView: VST3GenericView(inst: inst)) }
        let v = AUGenericView(audioUnit: au)
        v.showsExpertParameters = true
        return v
    }

    /// VST3: eigene Ansicht in einen Container hängen (Code des Plugins, im Prozess → Absturz-Markierung),
    /// sonst Schieberegler
    private func loadVST3View() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        container.autoresizingMask = [.width, .height]
        window.contentView = container
        core.pluginCatalog.beginOpen(key: inst.info.id, name: inst.info.name)
        let size = inst.openEditor(in: Unmanaged.passUnretained(container).toOpaque()) { [weak self] w, h in
            MainActor.assumeIsolated { self?.pluginResized(w, h) }
        }
        core.pluginCatalog.endOpen()
        guard let size else {
            window.contentView = nil
            install(genericView(), size: nil)
            return
        }
        vst3Container = container
        hasView = true
        container.frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        window.setContentSize(NSSize(width: size.width, height: size.height))
        if inst.editorResizable { window.styleMask.insert(.resizable) }
    }

    /// das Plugin möchte eine andere Größe (IPlugFrame::resizeView)
    private func pluginResized(_ w: Int, _ h: Int) {
        guard let c = vst3Container, w > 0, h > 0 else { return }
        resizingFromPlugin = true
        c.frame = NSRect(x: 0, y: 0, width: w, height: h)
        window.setContentSize(NSSize(width: w, height: h))
        resizingFromPlugin = false
    }
}

/// VST3 ohne eigene Ansicht: ein Schieberegler je Parameter (Wert-Text vom Plugin)
private struct VST3GenericView: View {
    let inst: PluginInstance
    @State private var values: [UInt32: Float] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if inst.parameters.isEmpty {
                    Text("keine parameter").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
                ForEach(inst.parameters, id: \.id) { p in
                    let v = values[p.id] ?? inst.value(p.id)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(verbatim: p.name.uppercased()).font(Theme.label(10, .bold)).foregroundStyle(Theme.bone)
                            Spacer()
                            Text(verbatim: inst.text(p.id, v) + (p.units.isEmpty ? "" : " " + p.units))
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted).monospacedDigit()
                        }
                        Slider(value: Binding(get: { Double(values[p.id] ?? inst.value(p.id)) },
                                              set: { values[p.id] = Float($0); inst.set(p.id, Float($0)) }), in: 0...1)
                            .tint(Theme.state)
                    }
                }
            }
            .padding(14)
        }
        .frame(minWidth: 380, minHeight: 120)
        .background(Theme.chitin)
    }
}
