import SwiftUI
import AppKit
import Darwin
import MixCore
import MixEngine

/// Statusleiste unten im Hauptfenster: links die aktuelle Meldung (zweite Zeile Detail/Fortschritt),
/// dahinter Audio-Status und Preparation, rechts Last-Anzeigen (DSP, Latenz, Aussetzer, Speicher, CPU).
/// Klick auf die Meldung: Verlauf der letzten 50.
struct StatusBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(MixModel.self) private var mix
    @State private var showHistory = false
    private var center: StatusCenter { StatusCenter.shared }

    var body: some View {
        HStack(alignment: .center, spacing: 10.z) {
            message
                .frame(minWidth: 240.z, maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let m = center.current, m.level == .error { center.dismiss(m) }
                    showHistory.toggle()
                }
                .popover(isPresented: $showHistory, arrowEdge: .top) { StatusHistory() }
                .help("Klick: letzte Meldungen")
            VStack(alignment: .trailing, spacing: 1.z) {
                HStack(spacing: 4.z) {
                    Text(mix.engineStatus).lineLimit(1).truncationMode(.middle)
                    Button("↻") { mix.reconnect() }
                        .buttonStyle(.plain)
                        .help("Audio-Interface neu verbinden")
                }
                HStack(spacing: 4.z) {
                    Text("Preparation: \(store.preparation.count)")
                    OverviewStatus()
                    AnalysisStatus()
                }
                .fixedSize()
            }
            .font(Theme.mono(10.z))
            .foregroundStyle(Theme.muted)
            .frame(minWidth: 200.z, maxWidth: 440.z, alignment: .trailing)
            if mix.prefs.ui.showMeters {
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 24.z)
                StatusMeters(engine: mix.engine)
            }
        }
        .padding(.horizontal, 8.z)
        .frame(height: 34.z)
        .background(Theme.chitin)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .onAppear { center.attach(mix.core) }
    }

    @ViewBuilder private var message: some View {
        if let m = center.current {
            VStack(alignment: .leading, spacing: 1.z) {
                HStack(spacing: 6.z) {
                    Text(verbatim: "◆").foregroundStyle(Self.color(m.level))
                    Text(verbatim: m.text).foregroundStyle(m.level == .info ? Theme.bone : Self.color(m.level)).lineLimit(1)
                        .truncationMode(.tail)
                    if center.activeCount > 1 {
                        Text(verbatim: "+\(center.activeCount - 1)").foregroundStyle(Theme.muted)
                    }
                    if m.cancellable {
                        Button("✕") { center.cancel(m) }.buttonStyle(.plain).foregroundStyle(Theme.muted).help("Abbrechen")
                    }
                }
                .font(Theme.mono(11.z))
                secondLine(m)
            }
        } else {
            VStack(alignment: .leading, spacing: 1.z) {
                Text(verbatim: store.status).font(Theme.mono(11.z)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(verbatim: " ").font(Theme.mono(9.5.z))
            }
        }
    }

    @ViewBuilder private func secondLine(_ m: StatusMessage) -> some View {
        HStack(spacing: 6.z) {
            if let p = m.progress {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.hairline)
                    Rectangle().fill(Self.color(m.level)).frame(width: 90.z * p)
                }
                .frame(width: 90.z, height: 3.z)
                if let t = m.progressText { Text(verbatim: t) }
            }
            Text(verbatim: m.detail ?? (m.progress == nil ? " " : "")).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.mono(9.5.z))
        .foregroundStyle(Theme.muted)
        .padding(.leading, 14.z)
    }

    static func color(_ l: StatusMessage.Level) -> Color {
        switch l {
        case .error: Theme.state
        case .warning: Theme.gold
        case .info: Theme.secondary
        case .ok: Theme.bone
        }
    }
}

/// Verlauf der letzten Meldungen (Popover der Statusleiste)
struct StatusHistory: View {
    private var center: StatusCenter { StatusCenter.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("MELDUNGEN").font(Theme.label(11.z)).foregroundStyle(Theme.bone)
                Spacer()
                Button("Leeren") { center.clearHistory() }.buttonStyle(.plain).font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            }
            .padding(8.z)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if center.history.isEmpty {
                Text("Keine Meldungen").font(Theme.mono(11.z)).foregroundStyle(Theme.muted).padding(8.z)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4.z) {
                        ForEach(center.history) { m in
                            HStack(alignment: .firstTextBaseline, spacing: 6.z) {
                                Text(verbatim: Theme.timeFormat.string(from: m.updated)).foregroundStyle(Theme.muted)
                                Text(verbatim: "◆").foregroundStyle(StatusBar.color(m.level))
                                VStack(alignment: .leading, spacing: 1.z) {
                                    Text(verbatim: m.text + (m.progressText.map { " · \($0)" } ?? ""))
                                        .foregroundStyle(m.level == .error ? Theme.state : Theme.bone)
                                    if let d = m.detail { Text(verbatim: d).font(Theme.mono(9.5.z)).foregroundStyle(Theme.muted) }
                                }
                                .textSelection(.enabled)
                            }
                            .font(Theme.mono(11.z))
                        }
                    }
                    .padding(8.z)
                }
                .frame(maxHeight: 360.z)
            }
        }
        .frame(width: 560.z)
        .background(Theme.void)
    }
}

// MARK: - Last-Anzeigen

/// Messwerte für die Anzeige, 4 Hz vom Kern geholt (DSP-Last, Aussetzer), Speicher und CPU 1 Hz.
/// Kein Observable: die Zeichenfläche liest selbst (kein SwiftUI-Layout pro Messung).
@MainActor
final class MeterSampler {
    static let shared = MeterSampler()

    struct Sample {
        var load = MixEngine.RenderLoad()
        /// Spitze mit Halten (1,5 s, dann fällt sie)
        var peakHold = 0.0
        var dropouts = 0
        var lastDropout: Date?
        var memoryBytes: UInt64 = 0
        var cpu = 0.0
    }

    private(set) var sample = Sample()
    private weak var engine: MixEngine?
    private var timer: Timer?
    private var ticks = 0
    private var peakAt = Date.distantPast
    private var lastCPU: (wall: Double, cpu: Double)?

    func attach(_ e: MixEngine) {
        engine = e
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.step() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        step()
    }

    /// Zähler zurücksetzen (Klick auf AUSSETZER)
    func resetDropouts() {
        engine?.resetOverloads()
        sample.dropouts = 0
        sample.lastDropout = nil
    }

    private func step() {
        guard let engine else { return }
        let now = Date()
        var s = sample
        let l = engine.takeLoad()
        s.load = l
        if !l.running || l.blocks == 0 {
            s.peakHold = 0
        } else if l.peak >= s.peakHold {
            s.peakHold = l.peak; peakAt = now
        } else if now.timeIntervalSince(peakAt) > 1.5 {
            s.peakHold = max(l.peak, s.peakHold * 0.7)
        }
        let drops = l.overloads + l.deviceOverloads
        if drops > s.dropouts { s.lastDropout = now }
        s.dropouts = drops
        if ticks % 4 == 0 {
            s.memoryBytes = Self.footprint()
            let wall = CACurrentMediaTime(), cpu = Self.cpuSeconds()
            if let p = lastCPU, wall > p.wall { s.cpu = (cpu - p.cpu) / (wall - p.wall) }
            lastCPU = (wall, cpu)
        }
        ticks += 1
        sample = s
    }

    /// Prozess-Speicher wie in der Aktivitätsanzeige (phys_footprint)
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// CPU-Zeit des Prozesses (alle Threads, Benutzer + System), Sekunden
    static func cpuSeconds() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}

/// Kompakte Anzeigen rechts in der Statusleiste (Zeichenfläche mit 4 Hz, ohne SwiftUI-Layout)
struct StatusMeters: View {
    let engine: MixEngine
    @State private var showDetails = false
    static let width: CGFloat = 352
    /// Bereich AUSSETZER (Klick setzt zurück)
    static let dropRange: ClosedRange<CGFloat> = 196...262

    var body: some View {
        LiveCanvas(fps: 4) { ctx, size in Self.draw(ctx, size, MeterSampler.shared.sample) }
            .frame(width: Self.width.z, height: 26.z)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { p in
                if Self.dropRange.contains(p.x / 1.z) { MeterSampler.shared.resetDropouts() } else { showDetails.toggle() }
            }
            .popover(isPresented: $showDetails, arrowEdge: .top) { MeterDetails() }
            .help("DSP-Last, Latenz, Aussetzer (Klick: zurücksetzen), Speicher, CPU – Klick: Details")
            .onAppear { MeterSampler.shared.attach(engine) }
    }

    static let labelFont = NSFont(name: "IBMPlexMono", size: 8) ?? .monospacedSystemFont(ofSize: 8, weight: .regular)
    static let valueFont = NSFont(name: "IBMPlexMono-SemiBold", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .semibold)
    static let smallFont = NSFont(name: "IBMPlexMono", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
    static let red = NSColor(Theme.state), bone = NSColor(Theme.bone), muted = NSColor(Theme.muted)

    static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat) -> CGFloat {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        a.draw(at: CGPoint(x: x, y: y))
        return a.size().width
    }

    static func megabytes(_ b: UInt64) -> String {
        let mb = Double(b) / 1_048_576
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    @MainActor static func draw(_ ctx: CGContext, _ size: CGSize, _ s: MeterSampler.Sample) {
        let l = s.load
        let top: CGFloat = 1, low: CGFloat = 12
        // DSP: Balken mit Spitze, rot ab 70 %
        _ = text("DSP", labelFont, muted, x: 0, y: top)
        let barX: CGFloat = 0, barY: CGFloat = 17, barW: CGFloat = 56, barH: CGFloat = 5
        ctx.setFillColor(CG.hairline)
        ctx.fill(CGRect(x: barX, y: barY, width: barW, height: barH))
        let avg = min(1, max(0, l.average)), hot = l.average > 0.7 || s.peakHold > 1
        ctx.setFillColor(hot ? red.cgColor : bone.cgColor)
        ctx.fill(CGRect(x: barX, y: barY, width: barW * avg, height: barH))
        if s.peakHold > 0 {
            ctx.setFillColor(s.peakHold > 0.7 ? red.cgColor : bone.cgColor)
            ctx.fill(CGRect(x: barX + min(barW - 1, barW * min(1, s.peakHold)), y: barY - 2, width: 1.5, height: barH + 4))
        }
        let pct = l.running ? String(format: "%.0f%%", l.average * 100) : "—"
        _ = text(pct, valueFont, hot ? red : bone, x: barX + barW + 5, y: low)
        _ = text(String(format: "▲%.0f", s.peakHold * 100), labelFont, s.peakHold > 0.7 ? red : muted, x: 24, y: top)

        // Latenz: Ausgabe in ms, Puffer und Rate
        let lx: CGFloat = 104
        _ = text(String(localized: "LATENZ"), labelFont, muted, x: lx, y: top)
        let ms = l.running ? String(format: "%.1f ms", l.outputLatency * 1000) : "—"
        let w = text(ms, valueFont, bone, x: lx, y: low)
        if l.bufferFrames > 0 {
            _ = text(String(format: "%d·%gk", l.bufferFrames, l.sampleRate / 1000), smallFont, muted, x: lx + w + 4, y: low + 1)
        }

        // Aussetzer: rot, wenn in der letzten Minute einer dazukam
        let dx = dropRange.lowerBound
        let recent = s.lastDropout.map { Date().timeIntervalSince($0) < 60 } ?? false
        _ = text(String(localized: "AUSSETZER"), labelFont, recent ? red : muted, x: dx, y: top)
        _ = text("\(s.dropouts)", valueFont, recent ? red : (s.dropouts > 0 ? bone : muted), x: dx, y: low)

        // Speicher, CPU
        let mx: CGFloat = 270
        _ = text("RAM", labelFont, muted, x: mx, y: top)
        _ = text(megabytes(s.memoryBytes), valueFont, bone, x: mx, y: low)
        let cx: CGFloat = 320
        _ = text("CPU", labelFont, muted, x: cx, y: top)
        _ = text(String(format: "%.0f%%", s.cpu * 100), valueFont, bone, x: cx, y: low)
    }
}

/// Details zu den Anzeigen (Klick auf die Anzeigen)
struct MeterDetails: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let s = MeterSampler.shared.sample, l = s.load
            VStack(alignment: .leading, spacing: 3.z) {
                Text("AUDIO-LAST").font(Theme.label(11.z)).foregroundStyle(Theme.bone).padding(.bottom, 4.z)
                row("DSP-Last (Mittel)", String(format: "%.1f %%", l.average * 100))
                row("DSP-Last (Spitze, gehalten)", String(format: "%.1f %%", s.peakHold * 100))
                row("Ausgabelatenz", String(format: "%.1f ms", l.outputLatency * 1000))
                row("Keylock-Vorlauf (ausgeglichen)", String(format: "%.1f ms", l.keylockLatency * 1000))
                row("Puffer", "\(l.bufferFrames) Frames · " + String(format: "%g kHz", l.sampleRate / 1000))
                row("Blöcke über Budget (eigene Messung)", "\(l.overloads)")
                row("Überlast-Meldungen des Geräts", "\(l.deviceOverloads)")
                row("Speicher", StatusMeters.megabytes(s.memoryBytes))
                row("CPU (alle Kerne, 100 % = ein Kern)", String(format: "%.0f %%", s.cpu * 100))
                Button("Aussetzer zurücksetzen") { MeterSampler.shared.resetDropouts() }
                    .buttonStyle(.plain).font(Theme.mono(10.z)).foregroundStyle(Theme.state).padding(.top, 6.z)
            }
            .font(Theme.mono(11.z))
            .padding(10.z)
            .frame(width: 380.z, alignment: .leading)
        }
        .background(Theme.void)
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(Theme.muted)
            Spacer()
            Text(verbatim: v).foregroundStyle(Theme.bone)
        }
    }
}
