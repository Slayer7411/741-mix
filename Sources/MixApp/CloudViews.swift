import SwiftUI
import LibraryCloud
import MixCore

/// unsichtbar im Hauptfenster: Collection, Decks (Pause beim Laden), Lokal-halten-Liste, Einstellungen
struct CloudHook: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser

    /// alles, was die Lokal-halten-Liste bestimmt
    private struct KeepSig: Equatable {
        var revision: Int
        var preparation: [String]
        var sources: [BrowserSource]
        var running: [String]
        var own: Int
    }

    /// Playlists/Smartlists in den Browser-Bereichen; größere Quellen zählen als Library, nicht als Set
    static let keepSourceLimit = 1000

    var body: some View {
        let loading = (0..<4).contains { mix.deck($0).loading }
        let sig = KeepSig(revision: store.revision, preparation: store.preparation,
                          sources: [browser.paneA.source, browser.paneB.source], running: store.running.map(\.key),
                          own: store.playlistRevision)
        let cloud = CloudLibrary.shared
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: mix.prefs.cloud, initial: true) { cloud.apply(mix.prefs.cloud) }
            .onChange(of: loading, initial: true) { cloud.setPaused(loading) }
            .onChange(of: store.revision, initial: true) { if !store.tracks.isEmpty { cloud.collectionChanged(store.tracks) } }
            .onChange(of: sig, initial: true) { cloud.setKeepPaths(keepPaths(sig)) }
    }

    private func keepPaths(_ sig: KeepSig) -> Set<String> {
        var tracks = store.tracks(for: .preparation) + store.running
        for s in sig.sources {
            switch s {
            case .collection, .history, .historyLive, .running, .preparation: continue
            default:
                let list = store.tracks(for: s)
                if list.count <= Self.keepSourceLimit { tracks += list }
            }
        }
        return Set(tracks.map(\.path))
    }
}

/// Spalte ☁ im Browser: ● lokal · ☁ nur online · ↓ lädt · ✕ fehlt · leer = keine Cloud-Datei
struct CloudCell: View {
    let path: String

    var body: some View {
        let b = Self.badge(path)
        CloudGlyph(glyph: b.glyph, color: b.color).help(b.help)
    }

    @MainActor static func badge(_ path: String) -> (glyph: String, color: Color, help: String) {
        guard CloudPaths.isCloudBacked(path) else { return ("", Theme.muted, "") }
        let c = CloudLibrary.shared
        if c.isFetching(path) { return ("↓", Theme.secondary, String(localized: "Wird heruntergeladen")) }
        if c.isQueued(path) { return ("↓", Theme.muted, String(localized: "Wartet auf Download")) }
        switch c.state(path) {
        case .local: return ("●", Theme.muted, String(localized: "Lokal"))
        case .cloud: return ("☁", Theme.gold, String(localized: "Nur online – Rechtsklick → Bereitmachen"))
        case .missing: return ("✕", Theme.state, String(localized: "Datei fehlt"))
        case .unknown: return ("·", Theme.muted, String(localized: "Noch nicht geprüft"))
        }
    }
}

/// ☁ ist in der Mono-Schrift winzig -> Systemschrift, Rest Mono
struct CloudGlyph: View {
    let glyph: String
    let color: Color
    var body: some View {
        Text(verbatim: glyph)
            .font(glyph == "☁" ? .system(size: 13.z) : Theme.mono(11.z))
            .foregroundStyle(color)
    }
}

/// Kontextmenü: Tracks einer Quelle herunterladen
struct CloudMenuButton: View {
    let label: String
    let tracks: () -> [Track]
    var body: some View {
        if CloudLibrary.shared.hasCloudTracks {
            Button("Bereitmachen (herunterladen)") { CloudLibrary.shared.makeReady(tracks(), label: label) }
        }
    }
}

/// Set-Check: Preparation + Quelle des Bereichs vollständig lokal? Liste der übrigen, ein Klick holt sie
struct SetCheckButton: View {
    @Environment(LibraryStore.self) private var store
    @Bindable var model: BrowserPaneModel
    @State private var show = false

    var body: some View {
        DeckButton(title: "SET-CHECK", active: show) { show.toggle() }
            .help("Preparation und diese Liste: alles lokal?")
            .popover(isPresented: $show, arrowEdge: .bottom) {
                SetCheckView(groups: groups())
            }
    }

    /// Preparation + Quelle dieses Bereichs (ohne ganze Collection / History)
    private func groups() -> [(String, [Track])] {
        var g: [(String, [Track])] = [("Preparation", store.tracks(for: .preparation))]
        switch model.source {
        case .collection, .preparation, .history, .historyLive: break
        default: g.append((model.source.title, model.base(from: store, history: nil)))
        }
        return g
    }
}

struct SetCheckView: View {
    let groups: [(String, [Track])]
    /// nur Selbsttest-Bild: Ergebnis vorgeben
    var preset: SetCheckResult?
    @State private var result: SetCheckResult?
    @State private var running = false

    var body: some View {
        let res = preset ?? result
        VStack(alignment: .leading, spacing: 8.z) {
            Text("SET-CHECK").font(Theme.label(13.z, .bold))
            Text(verbatim: groups.map { "\($0.0) \($0.1.count)" }.joined(separator: " · "))
                .font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
            if let res {
                if res.ready {
                    Text("◆ alle \(res.checked) tracks lokal").font(Theme.mono(11.z)).foregroundStyle(Theme.bone)
                } else {
                    summary(res)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2.z) {
                            ForEach(res.cloud) { row($0, "☁", Theme.gold) }
                            ForEach(res.unknown) { row($0, "·", Theme.muted) }
                            ForEach(res.missing) { row($0, "✕", Theme.state) }
                        }
                    }
                    .frame(maxHeight: 260.z)
                    HStack {
                        if !res.cloud.isEmpty || !res.unknown.isEmpty {
                            DeckButton(title: String(localized: "ALLE HOLEN (\(res.cloud.count + res.unknown.count))"), active: true) {
                                CloudLibrary.shared.makeReady(res.cloud + res.unknown, label: "Set-Check")
                            }
                        }
                        DeckButton(title: "NEU PRÜFEN") { check() }
                    }
                }
            } else {
                Text(running ? "prüfe …" : "").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12.z)
        .frame(width: 420.z, alignment: .leading)
        .background(Theme.chitin)
        .onAppear { if preset == nil { check() } }
    }

    private func summary(_ r: SetCheckResult) -> some View {
        var parts: [String] = []
        if !r.cloud.isEmpty { parts.append(String(localized: "\(r.cloud.count) nur online")) }
        if !r.unknown.isEmpty { parts.append(String(localized: "\(r.unknown.count) nicht prüfbar")) }
        if !r.missing.isEmpty { parts.append(String(localized: "\(r.missing.count) fehlen")) }
        return Text(verbatim: "\(r.checked - r.cloud.count - r.unknown.count - r.missing.count)/\(r.checked) " + String(localized: "lokal") + " · " + parts.joined(separator: " · "))
            .font(Theme.mono(11.z)).foregroundStyle(Theme.gold)
    }

    private func row(_ t: Track, _ glyph: String, _ color: Color) -> some View {
        HStack(spacing: 6.z) {
            CloudGlyph(glyph: glyph, color: color).frame(width: 14.z)
            Text(verbatim: CloudLibrary.displayName(t)).foregroundStyle(Theme.bone).lineLimit(1)
        }
        .font(Theme.mono(11.z))
    }

    private func check() {
        running = true
        result = nil
        CloudLibrary.shared.setCheck(groups.flatMap(\.1)) { r in
            running = false
            result = r
        }
    }
}

// MARK: - Einstellungen

struct CloudSettings: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var mix = mix
        let c = CloudLibrary.shared
        Form {
            Section("Cloud-Library") {
                LabeledContent("Stand") { Text(verbatim: stateLine(c)).foregroundStyle((c.counts[.cloud] ?? 0) > 0 ? Theme.gold : Theme.bone) }
                    .settingsAnchor("cloud.state")
                LabeledContent("Geprüft") {
                    HStack(spacing: 10) {
                        Text(verbatim: c.lastScan.map { Theme.timeFormat.string(from: $0) + String(format: " · %.2f s", c.scanSeconds) } ?? "—")
                        Button("Jetzt prüfen") { c.rescan(quiet: false) }
                    }
                }
                .settingsAnchor("cloud.checked")
                Text("spalte ☁ im browser: ● lokal · ☁ nur online · ↓ lädt · ✕ fehlt. rechtsklick auf tracks oder eine liste -> bereitmachen. set-check im browser-kopf: preparation + liste lokal? geprüft per dateistatus, ohne etwas zu laden; neu bei änderungen im ordner und alle 10 min.")
                    .settingsHint()
            }
            Section("Lokal halten, solange MINOS-741 läuft") {
                Picker("Lokal halten", selection: $mix.prefs.cloud.keepMode) {
                    ForEach(CloudKeepMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .settingsAnchor("cloud.keep")
                Picker("Gleichzeitige Downloads", selection: $mix.prefs.cloud.parallel) {
                    ForEach([1, 2, 3, 4], id: \.self) { Text(verbatim: "\($0)").tag($0) }
                }
                .settingsAnchor("cloud.parallel")
                Picker("Mindestens frei lassen", selection: $mix.prefs.cloud.minFreeGB) {
                    ForEach([5, 10, 20, 50], id: \.self) { Text(verbatim: "\($0) GB").tag($0) }
                }
                .settingsAnchor("cloud.minfree")
                Toggle("Beim Beenden offene Downloads an den Anbieter übergeben", isOn: $mix.prefs.cloud.handOffOnQuit)
                    .settingsAnchor("cloud.handoff")
                Text("ausgelagerte tracks (speicher optimieren) werden neu geholt. lokal halten lädt einzeln und zuletzt, bereitmachen geht vor, neue downloads warten, solange ein deck lädt. übergeben: der anbieter lädt nach dem beenden weiter, ohne MINOS-741.")
                    .settingsHint()
            }
            Section("Dauerhaft offline") {
                LabeledContent("Library-Ordner") {
                    Text(verbatim: c.folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "—")
                        .lineLimit(2).truncationMode(.head)
                }
                .settingsAnchor("cloud.folder")
                LabeledContent("Offline verfügbar") {
                    Text(verbatim: pinLine(c)).foregroundStyle(c.folderStatus?.pin == .notPinned ? Theme.gold : Theme.bone)
                }
                .settingsAnchor("cloud.offline")
                HStack(spacing: 8) {
                    Button("Im Finder zeigen") { c.revealFolder() }.disabled(c.folder == nil)
                    Button("Prüfen") { c.checkFolder() }.disabled(c.folder == nil)
                }
                .settingsControlColumn()
                Text("\(c.provider ?? "Google Drive"): rechtsklick auf den ordner im finder -> „Offline verfügbar machen“. der anbieter hält dann alles lokal, auch ohne MINOS-741. MINOS-741 ändert keine einstellungen des anbieters.")
                    .settingsHint()
            }
        }
        .onAppear {
            if c.lastScan == nil, !store.tracks.isEmpty { c.collectionChanged(store.tracks) }
            if c.folderStatus == nil { c.checkFolder() }
        }
    }

    private func stateLine(_ c: CloudLibrary) -> String {
        guard c.cloudTracks > 0 else { return String(localized: "keine Tracks in Cloud-Ordnern") }
        let n = c.counts
        var parts = [String(localized: "\(n[.local] ?? 0) lokal"), String(localized: "\(n[.cloud] ?? 0) nur online")]
        if let m = n[.missing], m > 0 { parts.append(String(localized: "\(m) fehlen")) }
        if let u = n[.unknown], u > 0 { parts.append(String(localized: "\(u) ungeprüft")) }
        if c.keepPending > 0 { parts.append(String(localized: "\(c.keepPending) werden geholt")) }
        return parts.joined(separator: " · ")
    }

    private func pinLine(_ c: CloudLibrary) -> String {
        if c.checkingFolder { return String(localized: "prüfe …") }
        guard let s = c.folderStatus else { return "—" }
        var t: String
        switch s.pin {
        case .pinned: t = String(localized: "ja (angeheftet)")
        case .notPinned: t = String(localized: "nein")
        case .unknown: t = String(localized: "nicht ermittelbar")
        }
        if let all = s.recursivelyDownloaded { t += " · " + (all ? String(localized: "alles lokal") : String(localized: "nicht alles lokal")) }
        return t
    }
}
