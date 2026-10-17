import AppKit
import SwiftUI
import MixCore

/// Fenster der Grundfunktionen (Über, Handbuch, Tastenkürzel, Protokoll, Collection-Backup). Gezeigt wird nur im
/// normalen Betrieb. Selbsttest und Ende-zu-Ende merken nur, welches Fenster verlangt wurde (`recorded`), und zeigen
/// nichts auf dem Bildschirm (Bilder: `BasicsShot`, offscreen).
@MainActor
enum BasicWindows {
    nonisolated(unsafe) static var recorded: [String] = []
    private static var windows: [String: NSWindow] = [:]

    /// Nur im laufenden Programm (Ereignisschleife läuft): Tests und Selbsttest zeigen nichts
    static var mayShow: Bool { !Session.isSelfTest && !E2E.isActive && NSApplication.shared.isRunning }

    /// Fenster `id` öffnen oder nach vorn holen; `content` wird beim ersten Öffnen gebaut
    static func show(_ id: String, title: String, size: NSSize, content: () -> AnyView) {
        recorded.append(id)
        guard mayShow else { return }
        if let w = windows[id] {
            w.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: content().zoomExempt())
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.contentView = host
        w.contentMinSize = NSSize(width: min(size.width, 420), height: min(size.height, 300))
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = NSColor(Theme.void)
        w.center()
        windows[id] = w
        w.makeKeyAndOrderFront(nil)
    }
}
