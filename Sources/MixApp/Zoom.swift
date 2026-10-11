import AppKit
import SwiftUI
import MixCore

/// Zoom des Hauptfensters wie im Webbrowser (⌘+ / ⌘− / ⌘0): Schriften und feste Größen der Oberfläche × Faktor,
/// gerendert in voller Auflösung. Views lesen ihn über `.z` (beobachtet -> neues Layout beim Wechsel).
/// Einstellungen und Nebenfenster bleiben bei 100 %, die Werkzeugleiste auch.
@MainActor @Observable
final class UIZoom {
    static let shared = UIZoom()
    var factor: CGFloat = 1
}

extension Int {
    /// Punkte × Zoom des Hauptfensters
    @MainActor var z: CGFloat { CGFloat(self) * UIZoom.shared.factor }
}

extension Double {
    /// Punkte × Zoom des Hauptfensters
    @MainActor var z: CGFloat { CGFloat(self) * UIZoom.shared.factor }
}

extension CGFloat {
    /// Punkte × Zoom des Hauptfensters
    @MainActor var z: CGFloat { self * UIZoom.shared.factor }
}

/// Zoom-Stufen (⌘+ / ⌘− / ⌘0, Menü DARSTELLUNG), Grenze je Bildschirm, Meldung in der Statusleiste
@MainActor
enum ZoomControl {
    /// Mindestgröße der Oberfläche bei 100 %
    static let minContent = CGSize(width: 1280, height: 860)

    /// größter Zoom, mit dem die Mindestgröße noch auf den Bildschirm des Fensters passt (mindestens 100 %)
    static func limit(_ w: NSWindow?) -> Double {
        guard let w, let screen = w.screen ?? NSScreen.main else { return ZoomSteps.range.upperBound }
        let full = w.styleMask.contains(.fullScreen)
        let area = full ? screen.frame : screen.visibleFrame
        let chrome = full ? 0 : w.frame.height - w.contentLayoutRect.height
        let z = min(area.width / minContent.width, (area.height - chrome) / minContent.height)
        return min(ZoomSteps.range.upperBound, max(1, (Double(z) * 100).rounded(.down) / 100))
    }

    static func step(_ a: ShortcutID, mix: MixModel) {
        let cur = ZoomSteps.clamp(mix.prefs.ui.zoom)
        let lim = limit(MainWindow.window)
        let z: Double = switch a {
        case .zoomIn: ZoomSteps.larger(than: cur, limit: lim)
        case .zoomOut: ZoomSteps.smaller(than: cur)
        default: 1
        }
        set(z, mix: mix, limited: a == .zoomIn && z < ZoomSteps.larger(than: cur))
    }

    static func set(_ z: Double, mix: MixModel, limited: Bool = false) {
        let z = ZoomSteps.clamp(z)
        let grow = z > mix.prefs.ui.zoom
        mix.prefs.ui.zoom = z
        apply(z)
        StatusCenter.post(.info, String(localized: "Zoom \(ZoomSteps.percent(z))"),
                          detail: limited ? String(localized: "größer passt nicht auf diesen Bildschirm") : nil, key: "zoom")
        if grow { DispatchQueue.main.async { growWindow(z) } }
    }

    /// Faktor für die Oberfläche (beim Start vor dem ersten Fenster, danach bei jeder Änderung)
    static func apply(_ z: Double) {
        let f = CGFloat(ZoomSteps.clamp(z))
        if UIZoom.shared.factor != f { UIZoom.shared.factor = f }
    }

    /// Fenster auf einem kleineren Bildschirm: Zoom auf das Mögliche begrenzen
    static func fit(mix: MixModel) {
        guard let w = MainWindow.window else { return }
        let lim = limit(w)
        if mix.prefs.ui.zoom > lim { set(lim, mix: mix, limited: true) }
    }

    /// Fenster kleiner als die Mindestgröße × Zoom -> größer machen, oben links bleibt, im Bildschirm
    private static func growWindow(_ z: Double) {
        guard let w = MainWindow.window, !w.styleMask.contains(.fullScreen) else { return }
        let have = w.contentLayoutRect.size
        let dw = max(0, minContent.width * z - have.width), dh = max(0, minContent.height * z - have.height)
        guard dw > 0.5 || dh > 0.5 else { return }
        var f = w.frame
        f.size.width += dw
        f.size.height += dh
        f.origin.y -= dh
        if let s = (w.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = max(s.minX, min(f.origin.x, s.maxX - f.width))
            f.origin.y = max(s.minY, min(f.origin.y, s.maxY - f.height))
        }
        w.setFrame(f, display: true)
    }
}

extension EnvironmentValues {
    /// Zoom für gemeinsame Bausteine (DeckButton, Knob …): im Hauptfenster gesetzt, Nebenfenster bleiben bei 1
    @Entry var uiZoom: CGFloat = 1
}

extension View {
    /// Systemsteuerelemente (Slider, Segmente) wachsen stufenweise mit: ab 130 % eine Größe größer, ab 170 % zwei
    func controlSize(zoomed base: ControlSize) -> some View { modifier(ZoomedControlSize(base: base)) }
}

private struct ZoomedControlSize: ViewModifier {
    @Environment(\.uiZoom) private var zoom
    let base: ControlSize

    func body(content: Content) -> some View {
        let all: [ControlSize] = [.mini, .small, .regular, .large]
        let i = all.firstIndex(of: base) ?? 0
        let step = zoom >= 1.7 ? 2 : zoom >= 1.3 ? 1 : zoom < 0.85 ? -1 : 0
        content.controlSize(all[max(0, min(all.count - 1, i + step))])
    }
}
