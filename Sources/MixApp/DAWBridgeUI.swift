import AppKit
import Observation
import SwiftUI
import MixCore
import MixEngine

/// Live-Brücke zur DAW (App-Seite): Empfänger starten / stoppen, Pakete gesammelt auf den Hauptthread, Zustand für
/// Baum (DAW), Deck-Streifen und Deck-Menü. Positionen werden nicht beobachtet (10 Pakete/s): die Streifen lesen sie
/// beim Zeichnen. Beobachtet wird nur, was die Anzeige umbaut (Clip-Liste, Verbindung, Clip je Deck).
@MainActor @Observable
final class DAWBridgeModel {
    static let shared = DAWBridgeModel()
    /// Schlüssel der Clips als Tracks (Quelle DAW)
    static let keyPrefix = "daw:"

    /// Clips in Anzeige-Reihenfolge (nur bei Listenänderung neu)
    private(set) var clips: [DAWBridge.Clip] = []
    private(set) var connected = false
    /// DAW spielt (Bildrate der Streifen)
    private(set) var songPlaying = false
    /// Clip-ID je Deck (gleiche Datei oder aus der DAW geladen), nil = keiner
    private(set) var deckClip: [String?] = [nil, nil, nil, nil]
    /// gebundener Port (0 = aus), Fehlertext beim Start
    private(set) var port: UInt16 = 0
    private(set) var startError: String?

    @ObservationIgnored private(set) var session = DAWSession()
    @ObservationIgnored private let receiver = DAWBridgeReceiver()
    @ObservationIgnored private let inbox = Inbox()
    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var deckPaths: [String] = ["", "", "", ""]
    @ObservationIgnored private var deckKeys: [String] = ["", "", "", ""]
    @ObservationIgnored private var lastStatus = ""
    /// Zeit je Übergabe an den Hauptthread (ms, Selbsttest)
    @ObservationIgnored private(set) var deliverMs: [Double] = []

    /// Pakete vom Empfänger-Thread, einmal je Hauptthread-Durchlauf abgeholt
    final class Inbox: @unchecked Sendable {
        private var list: [DAWBridge.Message] = []
        private var scheduled = false
        private let lock = NSLock()
        /// true = Abholung muss geplant werden
        func add(_ m: DAWBridge.Message) -> Bool {
            lock.withLock {
                list.append(m)
                if scheduled { return false }
                scheduled = true
                return true
            }
        }
        func take() -> [DAWBridge.Message] { lock.withLock { scheduled = false; defer { list = [] }; return list } }
    }

    private init() {
        receiver.onMessage = { [inbox] m in
            guard inbox.add(m) else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { DAWBridgeModel.shared.deliver() } }
        }
    }

    static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Einstellung anwenden: an/aus, Port (Selbsttest: vom System gewählter Port, nie der echte)
    func configure(enabled: Bool, port want: UInt16) {
        let target: UInt16 = Session.isSelfTest ? 0 : want
        if enabled, receiver.running, Session.isSelfTest || receiver.port == target { return }
        receiver.stop()
        port = 0
        startError = nil
        watchdog?.invalidate()
        watchdog = nil
        guard enabled else { reset(); return }
        do {
            try receiver.start(port: target)
            port = receiver.port
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { DAWBridgeModel.shared.checkAlive() }
            }
        } catch {
            startError = String(localized: "Port \(Int(want)) belegt oder gesperrt")
            StatusCenter.post(.warning, String(localized: "DAW-Brücke: \(startError ?? "")"), key: "dawbridge")
        }
    }

    private func deliver() {
        let t0 = CACurrentMediaTime()
        let msgs = inbox.take()
        let now = Self.now
        var changed = false
        for m in msgs { if session.apply(m, now: now) { changed = true } }
        if session.connected != connected { connected = session.connected; changed = true }
        let playing = session.song.playing && connected
        if playing != songPlaying { songPlaying = playing }
        if changed { publish() }
        deliverMs.append((CACurrentMediaTime() - t0) * 1000)
        if deliverMs.count > 200 { deliverMs.removeFirst(100) }
    }

    /// DAW still (Script aus, DAW beendet, abgestürzt): nach 2 s ohne Paket Liste leeren
    private func checkAlive() {
        guard connected, !session.alive(now: Self.now) else { return }
        reset()
    }

    private func reset() {
        session = DAWSession()
        connected = false
        songPlaying = false
        publish()
    }

    private func publish() {
        let list = session.orderedClips
        if list != clips { clips = list }
        updateDecks()
        publishTracks()
        let tracks = session.trackCount
        let text = connected ? String(localized: "DAW-Brücke: \(tracks) Spuren · \(list.count) Clips") : String(localized: "DAW-Brücke: keine Verbindung")
        if text != lastStatus {
            if connected || !lastStatus.isEmpty { StatusCenter.post(connected ? .ok : .info, text, key: "dawbridge") }
            lastStatus = text
        }
    }

    /// Collection-Track je Dateipfad (Metadaten der DAW-Clips); im Hintergrund gebaut, je Collection-Stand einmal
    @ObservationIgnored private var pathIndex: [String: String] = [:]
    @ObservationIgnored private var pathIndexRevision = -1
    @ObservationIgnored private var pathIndexBuilding = false

    private func publishTracks() {
        guard let library else { return }
        let list = clips
        if !list.isEmpty, pathIndexRevision != library.revision, !pathIndexBuilding {
            pathIndexBuilding = true
            let tracks = library.tracks, rev = library.revision
            Task.detached(priority: .utility) {
                var m: [String: String] = [:]
                m.reserveCapacity(tracks.count)
                for t in tracks where m[t.path] == nil { m[t.path] = t.key }
                await MainActor.run {
                    let me = DAWBridgeModel.shared
                    me.pathIndex = m
                    me.pathIndexRevision = rev
                    me.pathIndexBuilding = false
                    me.publishTracks()
                }
            }
        }
        library.setDAWTracks(list.compactMap { c in Self.track(for: c, base: pathIndex[c.file].flatMap { library.track($0) }) })
    }

    /// Deck-Tracks (Pfad, Schlüssel) aus DAWBridgeHook
    func setDecks(paths: [String], keys: [String]) {
        guard paths != deckPaths || keys != deckKeys else { return }
        deckPaths = paths
        deckKeys = keys
        updateDecks()
    }

    private func updateDecks() {
        let ids = (0..<4).map { d -> String? in
            guard d < deckPaths.count, !deckPaths[d].isEmpty else { return nil }
            if deckKeys[d].hasPrefix(Self.keyPrefix) {
                let id = String(deckKeys[d].dropFirst(Self.keyPrefix.count))
                if session.clips[id] != nil { return id }
            }
            return Self.best(clips.filter { $0.file == deckPaths[d] })?.id
        }
        if ids != deckClip { deckClip = ids }
    }

    /// spielend vor ausgewählt vor erstem
    static func best(_ l: [DAWBridge.Clip]) -> DAWBridge.Clip? { l.first { $0.playing } ?? l.first { $0.selected } ?? l.first }

    func clip(_ id: String?) -> DAWBridge.Clip? { id.flatMap { session.clips[$0] } }
    func clip(deck d: Int) -> DAWBridge.Clip? { d < deckClip.count ? clip(deckClip[d]) : nil }

    /// Position (gewarpt: Beats, sonst Sekunden), zwischen den Paketen mit dem Tempo weitergerechnet
    func position(of id: String) -> Double? { session.position(of: id, now: Self.now) }
    var tempo: Double { session.song.tempo }

    /// Clip als Track: Werte der Collection (gleiche Datei), Grid aus den Warp-Markern, Titel = Clip, Artist = Spur
    static func track(for c: DAWBridge.Clip, base: Track?) -> Track? {
        guard !c.file.isEmpty else { return nil }
        var t = base ?? Track(key: "", path: c.file)
        t.key = keyPrefix + c.id
        t.path = c.file
        if base == nil {
            t.title = c.name.isEmpty ? (c.file as NSString).lastPathComponent : c.name
            t.artist = c.trackName
            t.loose = true
        }
        t.comment = "DAW · " + c.trackName + (c.name.isEmpty ? "" : " · " + c.name)
        if let g = c.grid(duration: t.duration) {
            t.bpm = g.grid.bpm
            t.cues.removeAll { $0.kind == .grid || $0.kind == .load }
            t.cues.append(Cue(name: "DAW", kind: .grid, startMs: g.grid.anchor * 1000, lengthMs: 0, hotcue: -1))
        }
        t.buildSearchText()
        return t
    }

    /// Grid des Clips im Deck auf das Deck legen (Rückgängig), Meldung in der Statusleiste
    func applyGrid(deck d: Int, mix: MixModel) {
        guard let c = clip(deck: d) else { return }
        guard let g = c.grid(beatsPerBar: session.song.beatsPerBar, duration: mix.deck(d).duration) else {
            StatusCenter.post(.warning, String(localized: "DAW-Clip ohne Warp-Marker"), key: "dawbridge.grid")
            return
        }
        mix.applyDAWGrid(d, g.grid)
        StatusCenter.post(.ok, String(localized: "Deck \(deckLetters[d]): Grid aus der DAW · \(Self.summary(g))"), key: "dawbridge.grid")
    }

    static func summary(_ g: WarpGrid) -> String {
        let t = g.constant ? String(format: "%.2f BPM", g.grid.bpm)
            : String(format: "%.2f–%.2f BPM, Grid %.2f", g.tempoRange.lowerBound, g.tempoRange.upperBound, g.grid.bpm)
        return String(localized: "\(g.markers.count) Marker · \(t)")
    }
}

/// unsichtbar im Hauptfenster: Einstellung -> Empfänger, Deck-Tracks -> Clip je Deck
struct DAWBridgeHook: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    private struct Decks: Equatable { var paths: [String]; var keys: [String] }

    var body: some View {
        let ui = mix.prefs.ui
        let decks = Decks(paths: (0..<4).map { mix.deck($0).track?.path ?? "" }, keys: (0..<4).map { mix.deck($0).track?.key ?? "" })
        Color.clear.frame(width: 0, height: 0)
            .onAppear { DAWBridgeModel.shared.library = store }
            .onChange(of: [ui.dawBridge ? 1 : 0, ui.dawBridgePort], initial: true) {
                DAWBridgeModel.shared.configure(enabled: ui.dawBridge, port: UInt16(clamping: ui.dawBridgePort))
            }
            .onChange(of: decks, initial: true) { DAWBridgeModel.shared.setDecks(paths: decks.paths, keys: decks.keys) }
    }
}

/// Streifen unter der Deck-Übersicht, wenn die DAW einen Clip derselben Datei meldet: Beat- und Taktlinien aus den
/// Warp-Markern, Loop der DAW, Abspielzeiger der DAW (lila) und des Decks (rot), rechts der Abstand Deck – DAW
struct DAWClipStrip: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        let bridge = DAWBridgeModel.shared
        let id = bridge.deckClip[d]
        let clip = bridge.clips.first { $0.id == id }
        let duration = mix.deck(d).duration
        StripCanvas(clip: clip, duration: duration, deckPosition: { [mix, d] in mix.position(d) })
            .help("DAW-Clip \(clip?.trackName ?? "") · \(clip?.name ?? ""): Beatlinien aus den Warp-Markern, lila = Position in der DAW, rot = Deck")
    }
}

/// Grid-Streifen eines DAW-Clips (ohne Audio): x = Sekunden der Datei von 0 bis `duration` (0 = Clip-Bereich)
struct StripCanvas: View {
    let clip: DAWBridge.Clip?
    let duration: Double
    var deckPosition: (@MainActor () -> Double?)? = nil

    var body: some View {
        let bridge = DAWBridgeModel.shared
        let map = clip?.map
        let bpb = bridge.session.song.beatsPerBar
        // Bereich: ganze Datei (Deck) oder Clip-Start … -Ende
        let range: ClosedRange<Double> = {
            if duration > 0 { return 0...duration }
            guard let c = clip, let m = map else { return 0...1 }
            let a = m.sec(atBeat: min(c.start, c.loop?.lowerBound ?? c.start)), b = m.sec(atBeat: max(c.end, c.loop?.upperBound ?? c.end))
            return b > a ? a...b : a...(a + 1)
        }()
        let lines = map?.beats(in: range, beatsPerBar: bpb) ?? []
        let loop = clip.flatMap { c in c.looping ? c.loop.map { l in (map?.sec(atBeat: l.lowerBound) ?? l.lowerBound)...(map?.sec(atBeat: l.upperBound) ?? l.upperBound) } : nil }
        let id = clip?.id, warped = clip?.warping ?? true
        LiveCanvas(fps: bridge.songPlaying ? 30 : 4, running: clip != nil) { ctx, size in
            ctx.setFillColor(CG.wave); ctx.fill(CGRect(origin: .zero, size: size))
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return }
            func x(_ s: Double) -> CGFloat { CGFloat((s - range.lowerBound) / span) * size.width }
            if let l = loop {
                ctx.setFillColor(NSColor(Theme.secondary).withAlphaComponent(0.22).cgColor)
                ctx.fill(CGRect(x: x(l.lowerBound), y: 0, width: max(2, x(l.upperBound) - x(l.lowerBound)), height: size.height))
            }
            // Beats nur, wenn sie mindestens 3 pt auseinander liegen; Takte ab 2 pt, sonst jeder 4. Takt
            let px = lines.count > 1 ? size.width / CGFloat(lines.count) : size.width
            let barStep = px * CGFloat(bpb) < 2 ? 4 : 1
            var bar = 0
            for l in lines {
                if l.bar {
                    if bar % barStep == 0 {
                        ctx.setFillColor(CG.bone)
                        ctx.fill(CGRect(x: x(l.sec) - 0.5, y: 0, width: 1, height: size.height))
                    }
                    bar += 1
                } else if px >= 3 {
                    ctx.setFillColor(CG.muted)
                    ctx.fill(CGRect(x: x(l.sec) - 0.5, y: size.height * 0.55, width: 1, height: size.height * 0.45))
                }
            }
            var dawSec: Double?
            if let id, let p = DAWBridgeModel.shared.position(of: id) { dawSec = warped ? map?.sec(atBeat: p) : p }
            if let s = dawSec {
                ctx.setFillColor(NSColor(Theme.secondary).cgColor)
                ctx.fill(CGRect(x: x(s) - 1, y: 0, width: 2, height: size.height))
            }
            if let p = deckPosition?() {
                ctx.setFillColor(CG.state)
                ctx.fill(CGRect(x: x(p) - 1, y: 0, width: 2, height: size.height))
                if let s = dawSec, abs(p - s) < 30 {
                    ctx.setFillColor(CG.wave)
                    ctx.fill(CGRect(x: size.width - 64, y: 0, width: 64, height: size.height))
                    CG.text(String(format: "Δ %+.0f ms", (p - s) * 1000), size: max(8, size.height * 0.6), color: CG.boneNS,
                            rightAt: size.width - 3, y: 0)
                }
            }
        }
        .clipShape(Rectangle())
    }
}

/// Kopf der Quelle DAW im Browser: je Clip eine Zeile (Spur · Clip · Tempo) mit Grid-Streifen
struct DAWClipsPanel: View {
    var body: some View {
        let bridge = DAWBridgeModel.shared
        VStack(alignment: .leading, spacing: 3.z) {
            if bridge.clips.isEmpty {
                Text(bridge.connected ? "DAW verbunden: kein spielender oder ausgewählter Audio-Clip"
                                      : (bridge.port > 0 ? "Warte auf die DAW (Remote Script, UDP \(Int(bridge.port)))" : "DAW-Brücke aus (⌘, -> BROWSER)"))
                    .font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            }
            ForEach(bridge.clips.prefix(8)) { c in
                HStack(spacing: 6.z) {
                    Text(c.playing ? "▶" : c.selected ? "◆" : "·").font(Theme.mono(10.z)).foregroundStyle(c.playing ? Theme.state : Theme.muted)
                        .frame(width: 10.z)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.trackName.isEmpty ? c.name : "\(c.trackName) · \(c.name)").font(Theme.mono(10.z, .semibold)).lineLimit(1)
                        Text(c.grid().map(DAWBridgeModel.summary) ?? String(localized: "nicht gewarpt"))
                            .font(Theme.mono(9.z)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    .frame(width: 210.z, alignment: .leading)
                    StripCanvas(clip: c, duration: 0).frame(height: 14.z)
                        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 6.z).padding(.vertical, 4.z)
    }
}

/// ⌘, -> BROWSER: DAW-Brücke an / aus, Port, Zustand
struct DAWBridgeSettings: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        @Bindable var mix = mix
        let bridge = DAWBridgeModel.shared
        Section("DAW-Brücke") {
            Toggle("Warp-Marker und Position aus der DAW empfangen (Remote Script)", isOn: $mix.prefs.ui.dawBridge)
                .settingsAnchor("browser.daw")
            Stepper(value: Binding(get: { mix.prefs.ui.dawBridgePort }, set: { mix.prefs.ui.dawBridgePort = max(1024, min(65535, $0)) }),
                    in: 1024...65535) {
                Text(verbatim: "UDP-Port \(mix.prefs.ui.dawBridgePort)")
            }
            .settingsAnchor("browser.dawport")
            Text(bridge.startError ?? (bridge.connected ? String(localized: "verbunden: \(bridge.clips.count) Clips")
                                                        : String(localized: "keine Verbindung")))
                .settingsHint()
            Text("remote script aus extras/daw-bridge kopieren und als control surface wählen.")
                .settingsHint()
                .help("remote script aus extras/daw-bridge in den ordner „Remote Scripts“ der DAW kopieren und dort als control surface wählen. nur 127.0.0.1, port gleich in config.json des scripts.")
        }
    }
}
