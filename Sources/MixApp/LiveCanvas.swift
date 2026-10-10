import AppKit
import QuartzCore
import SwiftUI

/// Zeichenfläche mit eigenem Display-Link: läuft am SwiftUI-Graphen vorbei (kein Layout pro Frame).
struct LiveCanvas: NSViewRepresentable {
    var fps: Float = 30
    var running = true
    var draw: @MainActor (CGContext, CGSize) -> Void

    func makeNSView(context: Context) -> LiveCanvasView { LiveCanvasView() }

    func updateNSView(_ v: LiveCanvasView, context: Context) {
        v.drawer = draw
        v.configure(fps: fps, running: running)
        v.needsDisplay = true
    }
}

final class LiveCanvasView: NSView {
    var drawer: @MainActor (CGContext, CGSize) -> Void = { _, _ in }
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
        drawer(ctx, bounds.size)
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
