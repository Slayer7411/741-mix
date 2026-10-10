import SwiftUI
import AppKit
import MixCore

/// MUSIC FOLDERS: Musik-Ordner als Dateibaum. Ordner werden erst beim Aufklappen/Anzeigen im Hintergrund gelesen
/// und zwischengespeichert; Dateien aus der Collection zeigen deren Metadaten, alle anderen kommen als lose Tracks.
@MainActor @Observable
final class MusicFolderStore {
    /// eingestellte Ordner (⌘, → anzeige → browser); leer = Standard aus der Collection
    var configured: [String] = []
    /// tiefster Ordner mit 90 % der vorhandenen Collection-Dateien, beim Laden der Collection berechnet
    private(set) var defaultRoot: String?
    /// gelesene Ordner (eine Ebene): Unterordner + Audiodateien
    private(set) var listings: [String: MusicFolder.Listing] = [:]
    /// zählt jede neu gelesene Liste (Browser-Zwischenspeicher)
    private(set) var revision = 0

    /// rekursiv gelesene Ordner (Schalter UNTERORDNER)
    @ObservationIgnored private var deep: [String: MusicFolder.Listing] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    /// Stand je Ordner (f:/r: + Pfad) – der Browser sortiert nur neu, wenn sich sein eigener Ordner ändert
    @ObservationIgnored private var stamps: [String: Int] = [:]
    /// Pfad der Collection-Datei (Vergleichsform) → Track-Schlüssel, einmal je geladener Collection
    @ObservationIgnored private var index: [String: String] = [:]
    /// Dateien außerhalb der Collection, die schon angezeigt wurden (Laden, Vorhören, Controller)
    @ObservationIgnored private(set) var loose: [String: Track] = [:]
    @ObservationIgnored private var cache: [String: (stamp: [Int], tracks: [Track])] = [:]
    @ObservationIgnored private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var watchOrder: [String] = []
    @ObservationIgnored private var rescanPending: Set<String> = []
    /// höchstens 4 Ordner gleichzeitig lesen (Google Drive, Netzlaufwerke)
    @ObservationIgnored private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    var roots: [String] {
        if !configured.isEmpty { return configured }
        return defaultRoot.map { [$0] } ?? []
    }

    /// nach dem Laden der Collection (Index und Standard-Ordner im Hintergrund berechnet)
    func collectionLoaded(index: [String: String], defaultRoot: String?) {
        self.index = index
        self.defaultRoot = defaultRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music").path
        cache = [:]
        revision += 1
        loads += 1
    }
    @ObservationIgnored private var loads = 0

    /// Änderungsstand eines Ordners für den Browser-Zwischenspeicher (liest `revision` → beobachtet)
    func stamp(_ path: String, recursive: Bool) -> Int {
        _ = revision
        return loads &* 1_000_003 &+ (stamps[(recursive ? "r:" : "f:") + path] ?? 0)
    }

    /// Unterordner (nil = noch nicht gelesen, wird angestoßen)
    func subfolders(_ path: String) -> [String]? {
        guard let l = listings[path] else { request(path, recursive: false); return nil }
        return l.folders
    }

    /// Dateien eines Ordners als Tracks: aus der Collection (mit Metadaten) oder lose (grau, ohne Grid)
    func tracks(in path: String, recursive: Bool, library: LibraryStore) -> [Track] {
        guard let l = recursive ? deep[path] : listings[path] else { request(path, recursive: recursive); return [] }
        watch(path)
        let k = (recursive ? "r:" : "f:") + path
        let stamp = [stamp(path, recursive: recursive), library.revision]
        if let c = cache[k], c.stamp == stamp { return c.tracks }
        var out: [Track] = []
        out.reserveCapacity(l.files.count)
        for f in l.files {
            if let key = index[f.match], let t = library.byKey[key] {
                out.append(t)
            } else {
                loose[f.loose.key] = f.loose
                out.append(f.loose)
            }
        }
        cache[k] = (stamp, out)
        return out
    }

    /// Ordner (und darunter gelesene) neu einlesen – Rechtsklick „Neu einlesen“ oder Änderung im Dateisystem
    func rescan(_ path: String) {
        let inside = { (p: String) in p == path || p.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
        for p in listings.keys where inside(p) { request(p, recursive: false, force: true) }
        for p in deep.keys where inside(p) { request(p, recursive: true, force: true) }
        if listings[path] == nil { request(path, recursive: false, force: true) }
    }

    private func request(_ path: String, recursive: Bool, force: Bool = false) {
        let k = (recursive ? "r:" : "f:") + path
        guard force || !pending.contains(k) else { return }
        pending.insert(k)
        queue.addOperation { [weak self] in
            let l = MusicFolder.list(path, recursive: recursive)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(path, recursive: recursive, l) }
            }
        }
    }

    private func publish(_ path: String, recursive: Bool, _ l: MusicFolder.Listing) {
        pending.remove((recursive ? "r:" : "f:") + path)
        if recursive { deep[path] = l } else { listings[path] = l }
        stamps[(recursive ? "r:" : "f:") + path, default: 0] += 1
        revision += 1
    }

    /// angezeigte Ordner beobachten (höchstens 16): neue/gelöschte Dateien → neu einlesen (0,5 s gebündelt)
    private func watch(_ path: String) {
        if watchers[path] != nil { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rescanPending.insert(path).inserted else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated {
                        self.rescanPending.remove(path)
                        self.rescan(path)
                    }
                }
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers[path] = src
        watchOrder.append(path)
        if watchOrder.count > 16 { watchers.removeValue(forKey: watchOrder.removeFirst())?.cancel() }
    }
}

/// Baum-Knoten MUSIC FOLDERS: eingestellte Ordner, Unterordner klappen auf und werden erst dann gelesen
struct MusicFolderTree: View {
    @Environment(LibraryStore.self) private var store
    @Binding var selection: BrowserSource
    @State private var open = false
    @State private var expanded: Set<String> = []

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ForEach(store.folders.roots, id: \.self) { p in
                MusicFolderRow(path: p, expanded: $expanded)
            }
        } label: {
            MusicFolderRow.label("▸", "MUSIC FOLDERS")
        }
        .onAppear { expandToSelection() }
        .onChange(of: selection) { expandToSelection() }
        .onChange(of: store.folders.roots) { expandToSelection() }
    }

    /// gewählten Ordner sichtbar machen (z. B. nach dem Wiederherstellen der Sitzung)
    private func expandToSelection() {
        guard case let .folder(p) = selection,
              let root = store.folders.roots.first(where: { p == $0 || p.hasPrefix($0 + "/") }) else { return }
        open = true
        var dir = (p as NSString).deletingLastPathComponent
        while dir.count >= root.count, dir.hasPrefix(root) {
            expanded.insert(dir)
            if dir == root { break }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }
}

private struct MusicFolderRow: View {
    @Environment(LibraryStore.self) private var store
    let path: String
    @Binding var expanded: Set<String>

    var body: some View {
        let subs = store.folders.subfolders(path)
        if let subs, !subs.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(path) },
                                                set: { if $0 { expanded.insert(path) } else { expanded.remove(path) } })) {
                if expanded.contains(path) {
                    ForEach(subs, id: \.self) { MusicFolderRow(path: $0, expanded: $expanded) }
                }
            } label: { folderLabel }
        } else {
            folderLabel
        }
    }

    private var folderLabel: some View {
        Self.label("▱", (path as NSString).lastPathComponent)
            .help(path)
            .tag(BrowserSource.folder(path))
            .contextMenu {
                Button("Neu einlesen") { store.folders.rescan(path) }
                OverviewMenuButton { store.folders.tracks(in: path, recursive: true, library: store) }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
    }

    static func label(_ glyph: String, _ name: String) -> some View {
        HStack(spacing: 6) {
            Text(glyph).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 12)
            Text(name).font(Theme.mono(11)).foregroundStyle(Theme.bone).lineLimit(1)
        }
    }
}

/// Einstellungen → Anzeige → Browser: Musik-Ordner hinzufügen/entfernen
struct MusicFolderSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let list = mix.prefs.ui.musicFolders
        LabeledContent("Musik-Ordner (MUSIC FOLDERS)") {
            Button("Ordner hinzufügen …") { add() }
        }
        if list.isEmpty {
            Text("automatisch: \(store.folders.defaultRoot ?? "—")")
                .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
        }
        ForEach(list, id: \.self) { p in
            HStack {
                Text(verbatim: p).font(Theme.mono(10)).lineLimit(1).truncationMode(.middle).help(p)
                Spacer()
                Button("Entfernen") { mix.prefs.ui.musicFolders.removeAll { $0 == p } }
            }
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let d = store.folders.roots.first { panel.directoryURL = URL(fileURLWithPath: d) }
        guard panel.runModal() == .OK else { return }
        var list = mix.prefs.ui.musicFolders
        // erster eigener Ordner: der automatische bleibt dabei
        if list.isEmpty, let d = store.folders.defaultRoot { list = [d] }
        for u in panel.urls where !list.contains(u.path) { list.append(u.path) }
        mix.prefs.ui.musicFolders = list
    }
}

/// Selbsttest-Bild (MIX741_SELFTEST=1 MIX741_SHOT=browser:<png>): Baum mit aufgeklapptem MUSIC FOLDERS und die
/// Dateiliste eines Unterordners (MIX741_SHOT_FOLDER, sonst der erste), offscreen gerendert – kein Fenster auf dem
/// Bildschirm, kein Audio, keine Controller, keine Einstellungen geschrieben
@MainActor
enum BrowserShot {
    static func run(_ spec: String) -> Never {
        guard spec.hasPrefix("browser:") else { print("[shot] unbekannt: \(spec)"); exit(2) }
        let out = URL(fileURLWithPath: String(spec.dropFirst(8)))
        let store = LibraryStore()
        let history = HistoryStore()
        store.folders.configured = AppPrefs.load().ui.musicFolders
        store.load()
        func spin(_ s: Double, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(s)
            while Date() < end, !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(120) { !store.tracks.isEmpty }
        guard let root = store.folders.roots.first else { print("[shot] kein Musik-Ordner"); exit(1) }
        print("[shot] collection \(store.tracks.count) tracks · standard-ordner \(store.folders.defaultRoot ?? "-") · ordner \(store.folders.roots)")
        spin(30) { store.folders.subfolders(root) != nil }
        let env = ProcessInfo.processInfo.environment["MIX741_SHOT_FOLDER"]
        let folder = env ?? store.folders.subfolders(root)?.first ?? root
        let t0 = Date()
        spin(60) { store.folders.subfolders(folder) != nil }
        let scan = Date().timeIntervalSince(t0)
        let t1 = Date()
        let tracks = store.folders.tracks(in: folder, recursive: false, library: store)
        let map = Date().timeIntervalSince(t1)
        let inColl = tracks.filter { !$0.loose }.count
        print(String(format: "[shot] %@: %d dateien (%d in der collection, %d lose), lesen %.0f ms, zuordnen %.1f ms",
                     folder, tracks.count, inColl, tracks.count - inColl, scan * 1000, map * 1000))
        _ = store.folders.tracks(in: root, recursive: true, library: store)
        let t2 = Date()
        spin(120) { !store.folders.tracks(in: root, recursive: true, library: store).isEmpty }
        let all = store.folders.tracks(in: root, recursive: true, library: store)
        print(String(format: "[shot] unterordner %@: %d dateien (%d in der collection), lesen %.2f s",
                     root, all.count, all.filter { !$0.loose }.count, Date().timeIntervalSince(t2)))

        let view = HStack(spacing: 0) {
            SourceTree(selection: .constant(.folder(folder))).frame(width: 300)
            ShotList(tracks: Array(tracks.sorted { ($0.loose ? 1 : 0, $0.artist) < ($1.loose ? 1 : 0, $1.artist) }.prefix(40)))
        }
        .frame(width: 1100, height: 720)
        .background(Theme.background)
        .environment(store)
        .environment(history)
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = host
        spin(3)   // Unterordner der sichtbaren Knoten einlesen lassen
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out)
        print("[shot] \(out.path)")
        exit(0)
    }

    /// vereinfachte Tabelle (die echte TrackTable braucht das Audio-Modell)
    private struct ShotList: View {
        let tracks: [Track]
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(tracks) { t in
                    HStack(spacing: 8) {
                        Text(t.artist).frame(width: 200, alignment: .leading)
                        Text(t.title).frame(width: 260, alignment: .leading)
                        Text(t.bpm > 0 ? String(format: "%.2f", t.bpm) : "").frame(width: 60, alignment: .trailing)
                        Text(t.openKey).frame(width: 36)
                        Text(t.comment2).frame(width: 200, alignment: .leading)
                    }
                    .lineLimit(1)
                    .foregroundStyle(t.loose ? Theme.muted : Theme.bone)
                }
                Spacer()
            }
            .font(Theme.mono(11))
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.void)
        }
    }
}
