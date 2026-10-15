import AppKit
import QuartzCore
import SwiftUI

/// Zeichenfläche mit eigenem Display-Link: läuft am SwiftUI-Graphen vorbei (kein Layout pro Frame).
/// Gezeichnet wird in Punkten bei 100 %, der Zoom des Hauptfensters skaliert den Kontext.
struct LiveCanvas: NSViewRepresentable {
    var fps: Float = 30
    var running = true
    var draw: @MainActor (CGContext, CGSize) -> Void

    func makeNSView(context: Context) -> LiveCanvasView { LiveCanvasView() }

    func updateNSView(_ v: LiveCanvasView, context: Context) {
        v.drawer = draw
        v.zoom = context.environment.zoomExempt ? 1 : UIZoom.shared.factor
        v.configure(fps: fps, running: running)
        v.needsDisplay = true
    }

    /// nimmt den angebotenen Platz; ohne das misst SwiftUI die NSView bei jedem Layout über Auto Layout (fittingSize)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: LiveCanvasView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

final class LiveCanvasView: NSView {
    var drawer: @MainActor (CGContext, CGSize) -> Void = { _, _ in }
    var zoom: CGFloat = 1
    private var link: CADisplayLink?
    private var fps: Float = 30
    private var running = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Rechtsklick: Menü der umgebenden Fläche (Übersicht im Deck -> Track-Menü)
    override func menu(for e: NSEvent) -> NSMenu? { super.menu(for: e) ?? enclosingAreaMenu(for: e) }

    func configure(fps: Float, running: Bool) {
        guard fps != self.fps || running != self.running else { return }
        self.fps = fps
        self.running = running
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link?.isPaused = !running
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let l = displayLink(target: self, selector: #selector(step))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        l.isPaused = !running
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.scaleBy(x: zoom, y: zoom)
        drawer(ctx, CGSize(width: bounds.width / zoom, height: bounds.height / zoom))
    }
}

/// Theme-Farben als CGColor (für Zeichnen außerhalb von SwiftUI)
enum CG {
    static let void = NSColor(Theme.void).cgColor
    static let wave = NSColor(Theme.wave).cgColor
    static let bone = NSColor(Theme.bone).cgColor
    static let muted = NSColor(Theme.muted).cgColor
    static let hairline = NSColor(Theme.hairline).cgColor
    static let state = NSColor(Theme.state).cgColor
    static let boneNS = NSColor(Theme.bone), mutedNS = NSColor(Theme.muted), stateNS = NSColor(Theme.state)
    static let secondaryNS = NSColor(Theme.secondary)

    static func text(_ s: String, size: CGFloat, weight: String = "SemiBold", color: NSColor, rightAt x: CGFloat, y: CGFloat) {
        let font = NSFont(name: "IBMPlexMono-\(weight)", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .semibold)
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: CGPoint(x: x - a.size().width, y: y))
    }
}
