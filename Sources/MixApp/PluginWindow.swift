import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import CoreAudioKit
import MixEngine

/// Fenster mit der Oberfläche eines Plugins (eine FX-Unit, Instanz des ersten Decks; Änderungen gehen live an alle Decks).
/// Reihenfolge: AUv3-View-Controller, eigene Cocoa-Ansicht (v2), sonst die generische Ansicht.
@MainActor
final class PluginWindow: NSObject, NSWindowDelegate {
    private static var open: [Int: PluginWindow] = [:]

    private let unit: Int
    private let inst: PluginInstance
    private let core: MixController
    private let window: NSWindow
    private var viewController: NSViewController?
    private var hasView = false

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
        core.endPluginEdit(unit, inst)
        Self.open[unit] = nil
    }

    private func loadView() {
        let au = inst.audioUnit
        if isV3(au) {
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
        let v = AUGenericView(audioUnit: inst.audioUnit)
        v.showsExpertParameters = true
        return v
    }
}
