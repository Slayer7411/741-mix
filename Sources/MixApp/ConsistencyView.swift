import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MixCore

typealias Check = ConsistencyCheck

/// Zustand des Prüf-Fensters. Holt den Stand des Laufs 20× je Sekunde gebündelt (nie eine Änderung je Datei),
/// zeigt die letzten 2000 Protokollzeilen, behält alle Befunde.
@MainActor @Observable
final class ConsistencyModel {
    static let viewLines = 2000

    var lines: [ConsistencyRun.LogLine] = []
    var findings: [Check.Finding] = []
    var snap = ConsistencyRun.Snapshot()
    var filter: Check.Category?
    var showFindings = false
    var source = ""
    /// gemeinsamer Musik-Ordner der Collection: in Protokoll und Tabelle als „…/“ gekürzt
    var root = ""
    var started = false
    @ObservationIgnored private var run: ConsistencyRun?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLine = 0
    @ObservationIgnored weak var store: LibraryStore?

    var running: Bool { started && !snap.finished }

    func short(_ path: String) -> String {
        root.count > 1 && path.hasPrefix(root + "/") ? "…" + path.dropFirst(root.count) : path
    }
    /// Befund-Text mit gekürzten Pfaden
    func shortText(_ s: String) -> String { root.count > 1 ? s.replacingOccurrences(of: root + "/", with: "…/") : s }

    func start(store: LibraryStore, musicFolders: Bool) {
        run?.cancel()
        self.store = store
        lines = []; findings = []; snap = ConsistencyRun.Snapshot(); filter = nil; showFindings = false; lastLine = 0
        source = store.sourceURL?.path ?? LibraryStore.defaultNML.path
        root = store.folders.defaultRoot ?? ""
        var lists = Check.lists(in: store.root)
        if !store.preparation.isEmpty { lists.append(Check.KeyList(name: "Preparation", keys: store.preparation)) }
        let input = Check.Input(tracks: store.tracks, lists: lists, musicRoots: musicFolders ? store.folders.roots : [])
        snap.total = input.tracks.count
        run = ConsistencyRun.start(input)
        started = true
        timer?.invalidate()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll() {
        guard let run else { return }
        var s = run.snapshot(sinceLine: lastLine, sinceFinding: findings.count)
        lastLine = s.lastLine
        if !s.lines.isEmpty {
            lines.append(contentsOf: s.lines)
            if lines.count > Self.viewLines { lines.removeFirst(lines.count - Self.viewLines) }
        }
        if !s.findings.isEmpty { findings.append(contentsOf: s.findings) }
        s.lines = []; s.findings = []
        let ended = s.finished && !snap.finished
        snap = s
        if s.finished {
            timer?.invalidate(); timer = nil
            if ended, !findings.isEmpty { showFindings = true }
        }
    }

    /// stoppt sofort (Anzeige), Arbeiter hören vor der nächsten Datei auf
    func cancel() { run?.cancel(); poll() }

    var fraction: Double { snap.total > 0 ? Double(snap.done) / Double(snap.total) : (snap.finished ? 1 : 0) }

    var eta: TimeInterval? {
        guard running, snap.phase == .files, snap.done > 20 else { return nil }
        return snap.elapsed / Double(snap.done) * Double(snap.total - snap.done)
    }

    var visibleFindings: [Check.Finding] {
        let list = filter.map { c in findings.filter { $0.category == c } } ?? findings
        return list.sorted { ($0.category.isProblem ? 0 : 1, $0.category.rawValue, $0.path) < ($1.category.isProblem ? 0 : 1, $1.category.rawValue, $1.path) }
    }

    var summary: Check.Summary {
        Check.Summary(source: source, tracks: snap.total, checked: snap.done, ok: snap.ok, counts: snap.counts,
                      folderFiles: snap.folderFiles, elapsed: snap.elapsed, cancelled: snap.cancelled)
    }

    // MARK: Aktionen

    func save(csv: Bool) {
        let panel = NSSavePanel()
        let day = Theme.dateFormat.string(from: Date())
        panel.nameFieldStringValue = "minos-collection-check-\(day).\(csv ? "csv" : "txt")"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = csv ? Check.reportCSV(findings: findings) : Check.reportText(summary, findings: findings)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func showInFinder(_ ids: Set<Int>) {
        let urls = findings.filter { ids.contains($0.id) }.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if urls.isEmpty, let f = findings.first(where: { ids.contains($0.id) }) {
            // Datei fehlt: nächsten vorhandenen Ordner zeigen
            var dir = (f.path as NSString).deletingLastPathComponent
            while !dir.isEmpty, dir != "/", !FileManager.default.fileExists(atPath: dir) { dir = (dir as NSString).deletingLastPathComponent }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    func copyPaths(_ ids: Set<Int>) {
        let text = findings.filter { ids.contains($0.id) }.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func canReveal(_ ids: Set<Int>) -> Bool {
        guard let store, let f = findings.first(where: { ids.contains($0.id) }), let k = f.key else { return false }
        return store.byKey[k] != nil
    }

    /// Track im Browser zeigen: aktiver Bereich auf TRACK COLLECTION, Suche/Filter leer, Zeile gewählt
    func reveal(_ ids: Set<Int>) {
        guard let store, let browser = store.browser, let f = findings.first(where: { ids.contains($0.id) }),
              let key = f.key, store.byKey[key] != nil else { return }
        let pane = browser.activePane
        pane.source = .collection
        pane.search = ""
        pane.roles = []
        pane.tags = []
        pane.selection = [key]
        browser.activePaneID = pane.id
        browser.scrollRequest = (pane.id, key)
        MainWindow.window?.makeKeyAndOrderFront(nil)
    }
}

/// Fenster „Collection prüfen“: eines je App, schließen bricht einen laufenden Prüflauf ab.
@MainActor
enum ConsistencyWindow {
    private static var window: NSWindow?
    private static let model = ConsistencyModel()
    private final class Delegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            MainActor.assumeIsolated { ConsistencyWindow.model.cancel() }
        }
    }
    private static let delegate = Delegate()

    /// öffnen und (wenn noch nicht gelaufen oder fertig) prüfen
    static func show(store: LibraryStore, restart: Bool = true) {
        if let w = window, w.isVisible, model.started {   // schon offen: nur nach vorn, Ergebnis bleibt
            w.makeKeyAndOrderFront(nil)
            return
        }
        if window == nil {
            let host = NSHostingView(rootView: ConsistencyView(model: model, musicFolders: { AppPrefs.load().ui.checkMusicFolders })
                .environment(store).zoomExempt())
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            w.title = String(localized: "Collection prüfen")
            w.contentView = host
            w.contentMinSize = NSSize(width: 760, height: 520)
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(Theme.void)
            w.delegate = delegate
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        if restart, !model.running, !store.tracks.isEmpty {
            model.start(store: store, musicFolders: AppPrefs.load().ui.checkMusicFolders)
        }
    }
}

struct ConsistencyView: View {
    @Bindable var model: ConsistencyModel
    let musicFolders: () -> Bool
    @Environment(LibraryStore.self) private var store
    @State private var selection: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progress
            counters
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 4) {
                DeckButton(title: "LOG", active: !model.showFindings) { model.showFindings = false }
                DeckButton(title: String(localized: "BEFUNDE \(model.findings.count)"), active: model.showFindings) { model.showFindings = true }
                if model.showFindings, let f = model.filter {
                    DeckButton(title: f.tag.trimmingCharacters(in: .whitespaces) + " ✕", active: true, color: color(f)) { model.filter = nil }
                }
                Spacer()
                if model.lines.count >= ConsistencyModel.viewLines {
                    Text("letzte \(ConsistencyModel.viewLines) zeilen · alle befunde unter BEFUNDE").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
            }
            if model.showFindings { findingsTable } else { log }
            footer
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 520)
        .background(Theme.void)
        .foregroundStyle(Theme.bone)
        .preferredColorScheme(.dark)
    }

    // MARK: Kopf

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("◆ COLLECTION PRÜFEN").font(Theme.label(18, .bold))
                Spacer()
                badge
            }
            Text("\(URL(fileURLWithPath: model.source).lastPathComponent) · \(model.snap.total) tracks · nur lesen, es wird nichts geändert")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
            if !model.root.isEmpty {
                Text("… = \(model.root)").font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private var badge: some View {
        let (text, bg): (String, Color) = !model.started ? ("BEREIT", Theme.hairline)
            : model.snap.cancelled ? ("ABGEBROCHEN", Theme.state)
            : model.snap.finished ? ("FERTIG", Theme.bone)
            : ("LÄUFT", Theme.secondary)
        return Text(LocalizedStringKey(text)).font(Theme.label(11, .bold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(bg == Theme.bone ? Theme.void : Theme.bone)
            .background(bg)
    }

    private var phaseText: String {
        switch model.snap.phase {
        case .files: String(localized: "DATEIEN")
        case .playlists: String(localized: "PLAYLISTS")
        case .folders: String(localized: "MUSIC FOLDERS · \(model.snap.folderFiles) dateien")
        case .done: model.snap.cancelled ? String(localized: "ABGEBROCHEN") : String(localized: "FERTIG")
        }
    }

    private var progress: some View {
        let s = model.snap
        let width = 64
        let filled = Int((model.fraction * Double(width)).rounded(.down))
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: max(0, width - filled))
        var info = "\(s.done) / \(s.total) · \(Int((model.fraction * 100).rounded(.down))) % · \(Theme.time(s.elapsed))"
        if let eta = model.eta { info += " · " + String(localized: "noch ~\(Theme.time(eta))") }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(bar).font(Theme.mono(12)).foregroundStyle(s.cancelled ? Theme.state : Theme.bone).lineLimit(1)
                Text(phaseText).font(Theme.label(11, .bold)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Text(info).font(Theme.mono(11)).monospacedDigit()
            Text("› " + (s.current.isEmpty ? (s.finished ? summaryLine : "…") : model.short(s.current)))
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var summaryLine: String {
        let s = model.snap
        let problems = Check.Category.allCases.filter(\.isProblem).reduce(0) { $0 + (s.counts[$1] ?? 0) }
        let hints = Check.Category.allCases.filter { !$0.isProblem }.reduce(0) { $0 + (s.counts[$1] ?? 0) }
        return String(localized: "\(s.ok) ok · \(problems) probleme · \(hints) hinweise · \(Theme.time(s.elapsed))")
    }

    // MARK: Zähler

    private var counters: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8), alignment: .leading, spacing: 4) {
            counter(nil)
            ForEach(Check.Category.allCases, id: \.self) { counter($0) }
        }
    }

    private func counter(_ c: Check.Category?) -> some View {
        let n = c.map { model.snap.counts[$0] ?? 0 } ?? model.snap.ok
        let tint = c.map { n > 0 ? color($0) : Theme.muted } ?? Theme.bone
        let selected = c != nil && model.filter == c && model.showFindings
        return Button {
            guard let c else { return }
            model.filter = model.filter == c && model.showFindings ? nil : c
            model.showFindings = true
        } label: {
            HStack(spacing: 6) {
                Text(c?.tag ?? "OK  ").font(Theme.mono(11, .bold)).foregroundStyle(tint)
                Text("\(n)").font(Theme.mono(11)).monospacedDigit().foregroundStyle(n > 0 ? Theme.bone : Theme.muted)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(selected ? Theme.chitinRaised : Theme.chitin)
            .overlay(Rectangle().stroke(selected ? tint : Theme.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(c.map(label) ?? String(localized: "Tracks ohne Befund"))
    }

    private func color(_ c: Check.Category) -> Color { c.isProblem ? Theme.state : Theme.secondary }

    private func label(_ c: Check.Category) -> String {
        switch c {
        case .missing: String(localized: "Datei fehlt")
        case .unreadable: String(localized: "keine Leserechte")
        case .empty: String(localized: "Datei ist leer (0 Byte)")
        case .badAudio: String(localized: "kein lesbares Audio")
        case .duration: String(localized: "Dauer weicht mehr als 2 s von der Collection ab")
        case .pathCase: String(localized: "Pfad auf der Platte in anderer Groß-/Kleinschreibung")
        case .unicodeForm: String(localized: "gleicher Name, andere Unicode-Form (NFC/NFD) – auf dem Mac ohne Folgen")
        case .name: String(localized: "Dateiname enthält weder Titel noch Artist")
        case .dupPath: String(localized: "gleiche Datei mehrfach in der Collection")
        case .dupTrack: String(localized: "gleicher Artist + Titel, andere Datei")
        case .noAnalysis: String(localized: "Analyse fehlt (BPM, Grid, Key, Lautheit)")
        case .grid: String(localized: "Grid: BPM außerhalb 60–200 oder Anker hinter dem Ende")
        case .dangling: String(localized: "Playlist-Eintrag ohne Track in der Collection")
        case .notInCollection: String(localized: "Datei im Musik-Ordner, nicht in der Collection")
        }
    }

    // MARK: Protokoll

    private var log: some View {
        LogTextView(lines: model.lines, tail: model.running, short: model.short, shortText: model.shortText)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
    }

    // MARK: Befunde

    private var findingsTable: some View {
        let rows = model.visibleFindings
        return Table(rows, selection: $selection) {
            TableColumn("") { (f: Check.Finding) in Text(f.category.tag).foregroundStyle(color(f.category)) }.width(38)
            TableColumn("Pfad") { (f: Check.Finding) in Text(model.short(f.path)).lineLimit(1).truncationMode(.middle).help(f.path) }
                .width(min: 200, ideal: 520)
            TableColumn("Befund") { (f: Check.Finding) in Text(model.shortText(f.detail)).foregroundStyle(Theme.muted).lineLimit(1).help(f.detail) }
                .width(min: 120, ideal: 300)
        }
        .font(Theme.mono(11))
        .scrollContentBackground(.hidden)
        .background(Theme.chitin)
        .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        .contextMenu(forSelectionType: Int.self) { ids in
            Button("Im Browser zeigen") { model.reveal(ids) }.disabled(!model.canReveal(ids))
            Button("Im Finder zeigen") { model.showInFinder(ids) }
            Button("Pfad kopieren") { model.copyPaths(ids) }
        } primaryAction: { ids in
            if model.canReveal(ids) { model.reveal(ids) } else { model.showInFinder(ids) }
        }
    }

    // MARK: Knöpfe

    private var footer: some View {
        HStack(spacing: 6) {
            if model.running {
                Text("abbrechen behält die befunde bis hierher").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                Spacer()
                DeckButton(title: "ABBRECHEN", active: true) { model.cancel() }
            } else {
                DeckButton(title: "NEU PRÜFEN") { model.start(store: store, musicFolders: musicFolders()) }
                    .disabled(store.tracks.isEmpty)
                Spacer()
                DeckButton(title: "BERICHT TXT …") { model.save(csv: false) }.disabled(!model.started)
                DeckButton(title: "BERICHT CSV …") { model.save(csv: true) }.disabled(!model.started)
                DeckButton(title: "SCHLIESSEN", active: true, color: Theme.bone) { NSApp.keyWindow?.performClose(nil) }
            }
        }
    }
}

/// Protokoll als Textfeld. Während des Laufs nur das Ende, das ins Feld passt (höchstens 10× je Sekunde neu
/// gezeichnet): ein mitlaufendes Dokument mit 2000 Zeilen kostete je Abruf 35–70 ms Hauptthread (Text neu zeichnen).
/// Danach alle gehaltenen Zeilen (bis 2000) zum Zurückscrollen.
struct LogTextView: NSViewRepresentable {
    let lines: [ConsistencyRun.LogLine]
    let tail: Bool
    let short: (String) -> String
    let shortText: (String) -> String

    final class Coordinator {
        var shownLast = -1
        var shownTail = false
        var drawn: CFTimeInterval = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    private static let font = NSFont(name: "IBM Plex Mono", size: 10.5) ?? .monospacedSystemFont(ofSize: 10.5, weight: .regular)

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView()
        sv.drawsBackground = true
        sv.backgroundColor = NSColor(Theme.chitin)
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(Theme.chitin)
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.layoutManager?.allowsNonContiguousLayout = true
        // feste Breite, eine Zeile je Datei (lange Pfade in der Mitte gekürzt): Breite ändert sich nie -> kein Neuaufbau
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        guard let tv = sv.documentView as? NSTextView, let storage = tv.textStorage else { return }
        let c = context.coordinator
        let last = lines.last?.id ?? 0
        guard last != c.shownLast || tail != c.shownTail else { return }
        let now = CACurrentMediaTime()
        if tail, c.shownTail, now - c.drawn < 0.1 { return }   // nächster Abruf zeichnet
        let shown: ArraySlice<ConsistencyRun.LogLine>
        if tail {
            let lineHeight = max(1, NSLayoutManager().defaultLineHeight(for: Self.font))
            shown = lines.suffix(max(5, Int(sv.contentView.bounds.height / lineHeight)))
        } else {
            shown = lines[...]
        }
        storage.setAttributedString(render(shown))
        tv.scrollToEndOfDocument(nil)
        c.shownLast = last; c.shownTail = tail; c.drawn = now
    }

    private func render(_ list: ArraySlice<ConsistencyRun.LogLine>) -> NSAttributedString {
        let font = Self.font
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingMiddle
        // Pfad-Spalte über einen Tabstopp: Leerzeichen-Breiten verschoben die Spalte je nach Zeile
        para.tabStops = [NSTextTab(textAlignment: .left, location: ceil(("MISS  " as NSString).size(withAttributes: [.font: font]).width))]
        let bone = NSColor(Theme.bone), muted = NSColor(Theme.muted)
        let red = NSColor(Theme.state), lila = NSColor(Theme.secondary)
        let out = NSMutableAttributedString()
        for (i, l) in list.enumerated() {
            let start = out.length
            if i > 0 { out.append(NSAttributedString(string: "\n", attributes: [.font: font])) }
            defer { out.addAttribute(.paragraphStyle, value: para, range: NSRange(location: start, length: out.length - start)) }
            out.append(NSAttributedString(string: (l.category?.tag ?? "OK").trimmingCharacters(in: .whitespaces),
                                          attributes: [.font: font, .foregroundColor: l.category.map { $0.isProblem ? red : lila } ?? muted]))
            out.append(NSAttributedString(string: "\t" + short(l.path), attributes: [.font: font, .foregroundColor: l.category == nil ? muted : bone]))
            if !l.detail.isEmpty {
                out.append(NSAttributedString(string: "  · " + shortText(l.detail), attributes: [.font: font, .foregroundColor: muted]))
            }
        }
        return out
    }
}

/// Selbsttest ohne Fenster (MIX741_SELFTEST=1 MIX741_CHECK=1): echte Collection nur lesen, prüfen, Zähler je
/// Kategorie und Dauer ausgeben. MIX741_CHECK_LIST=<n>: je Kategorie die ersten n Befunde.
@MainActor
enum ConsistencyCLI {
    nonisolated static var requested: Bool { Session.isSelfTest && ProcessInfo.processInfo.environment["MIX741_CHECK"] == "1" }

    static func run() -> Never {
        let env = ProcessInfo.processInfo.environment
        let url = env["MIX741_CHECK_NML"].map { URL(fileURLWithPath: $0) } ?? LibraryStore.defaultNML
        func log(_ s: String) { print("[check] \(s)"); fflush(stdout) }
        guard let input = input(url: url) else { log("collection nicht lesbar: \(url.path)"); exit(1) }
        log("\(url.path) · \(input.tracks.count) tracks · \(input.lists.count) playlists · musik-ordner \(input.musicRoots)")
        let run = ConsistencyRun.start(input)
        while true {
            let s = run.snapshot(sinceLine: .max, sinceFinding: .max)
            if s.finished { break }
            log(String(format: "%@ %d / %d · %.1f s", s.phase.rawValue, s.done, s.total, s.elapsed))
            Thread.sleep(forTimeInterval: 2)
        }
        run.wait()
        let s = run.snapshot(sinceLine: .max, sinceFinding: .max)
        let f = run.allFindings
        log(String(format: "fertig in %.1f s · %d / %d tracks geprüft · %d ok · %d dateien in musik-ordnern",
                   s.elapsed, s.done, s.total, s.ok, s.folderFiles))
        let n = Int(env["MIX741_CHECK_LIST"] ?? "") ?? 0
        for c in Check.Category.allCases {
            log("\(c.tag) \(String(format: "%6d", s.counts[c] ?? 0))  \(c.rawValue)")
            for x in f.filter({ $0.category == c }).prefix(n) { log("       \(x.path) · \(x.detail)") }
        }
        exit(0)
    }

    /// Prüf-Eingabe aus der Collection-Datei (nur lesen) wie in der App: Playlists, Musik-Ordner aus den Einstellungen
    nonisolated static func input(url: URL) -> Check.Input? {
        guard let c = try? NMLParser.parse(url: url) else { return nil }
        let configured = AppPrefs.load().ui.musicFolders
        let roots = !configured.isEmpty ? configured
            : MusicFolder.defaultRoot(paths: c.tracks.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }).map { [$0] } ?? []
        let ui = AppPrefs.load().ui
        return Check.Input(tracks: c.tracks, lists: Check.lists(in: c.root), musicRoots: ui.checkMusicFolders ? roots : [])
    }
}

/// Bild offscreen (MIX741_SELFTEST=1 MIX741_SHOT=consistency:<png>): echter Prüflauf über die Collection (nur lesen),
/// <name>-running.png bei ~40 %, <name>-done.png nach dem Ende (Befunde). Kein sichtbares Fenster, kein Audio.
@MainActor
enum ConsistencyShot {
    static func run(_ spec: String) -> Never {
        let base = URL(fileURLWithPath: String(spec.dropFirst("consistency:".count))).deletingPathExtension()
        NSApplication.shared.setActivationPolicy(.prohibited)
        let store = LibraryStore()
        store.folders.configured = AppPrefs.load().ui.musicFolders
        store.load()
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(120) { !store.tracks.isEmpty }
        let model = ConsistencyModel()
        let view = ConsistencyView(model: model, musicFolders: { true }).environment(store)
        let host = NSHostingView(rootView: view)
        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        let win = NSWindow(contentRect: rect.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        host.frame = rect
        // längste Lücke des Hauptthreads während des Laufs (20-Hz-Abruf + Protokoll-Darstellung)
        var last = CACurrentMediaTime(), worst = 0.0
        let tick = Timer(timeInterval: 1.0 / 240, repeats: true) { _ in
            let now = CACurrentMediaTime(); worst = max(worst, now - last)
            if now - last > 0.03 { print(String(format: "[hitch] %.0f ms bei %d / %d", (now - last) * 1000, model.snap.done, model.snap.total)) }
            last = now
        }
        RunLoop.main.add(tick, forMode: .common)
        model.start(store: store, musicFolders: AppPrefs.load().ui.checkMusicFolders)
        func shot(_ name: String) {
            spin(0.3)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let url = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("[shot] \(url.path)")
        }
        spin(600) { model.fraction >= 0.4 || model.snap.finished }
        let runGap = worst
        shot("running")
        worst = 0
        spin(900) { model.snap.finished }
        print(String(format: "[shot] fertig in %.1f s · %d befunde · längste lücke hauptthread %.0f ms (bis 40 %%), %.0f ms (danach)",
                     model.snap.elapsed, model.findings.count, runGap * 1000, worst * 1000))
        shot("done")
        exit(0)
    }
}
