import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MixCore
import MixEngine

/// Einrichtung (Sheet über dem Hauptfenster): Collection, Musik-Ordner, Ausgabe, Netzwerk. Erscheint beim Start nur,
/// wenn etwas fehlt (keine Collection, gespeichertes Gerät weg) oder noch keine Einstellungen da sind. Jeder Schritt ist
/// überspringbar, nichts wird gelöscht. Menü „Einrichtung …“ öffnet sie jederzeit.
/// `MIX741_SETUP=off` unterdrückt sie (Ende-zu-Ende-Läufe, Tests/E2E/README.md); der Selbsttest nie.
@MainActor @Observable
final class SetupFlow {
    static let shared = SetupFlow()

    enum Step: String, CaseIterable, Identifiable {
        case collection, music, audio, network, done
        var id: String { rawValue }
        /// Nummer ab 1 (Anzeige „Schritt 2 von 5“)
        var number: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    }

    enum Reason: String {
        case firstLaunch, collectionMissing, deviceMissing
    }

    /// Macht die Einrichtung Sinn? Reine Entscheidung, ohne Oberfläche (Tests)
    nonisolated static func reasons(firstLaunch: Bool, collectionFound: Bool, deviceMissing: Bool) -> [Reason] {
        var r: [Reason] = []
        if firstLaunch { r.append(.firstLaunch) }
        if !collectionFound { r.append(.collectionMissing) }
        if deviceMissing { r.append(.deviceMissing) }
        return r
    }

    /// Ohne gespeicherte Einstellungen beim Start (vor dem ersten Schreiben festgehalten, siehe main.swift)
    nonisolated(unsafe) static var firstLaunch = false

    /// unterdrückt: Selbsttest, oder `MIX741_SETUP=off`
    nonisolated static var suppressed: Bool {
        Session.isSelfTest || ProcessInfo.processInfo.environment["MIX741_SETUP"] == "off"
    }

    static let privacyLocalNetwork = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    var shown = false
    var step = Step.collection
    /// Gründe der letzten Prüfung beim Start (leer = nichts zu tun)
    private(set) var reasons: [Reason] = []
    private(set) var checked = false
    @ObservationIgnored private weak var mix: MixModel?

    /// Modell des Hauptfensters; einmal beim Erscheinen
    func attach(_ mix: MixModel) { self.mix = mix }

    /// Start: prüfen, ob die Einrichtung gebraucht wird; zeigt sie dann (außer unterdrückt)
    func checkAtStart(mix: MixModel) {
        guard !checked else { return }
        checked = true
        attach(mix)
        mix.refreshDevices()
        let uid = mix.deviceUID
        let missing = uid != nil && !mix.outputDevices.contains { $0.uid == uid }
        reasons = Self.reasons(firstLaunch: Self.firstLaunch, collectionFound: FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path),
                               deviceMissing: missing)
        guard !Self.suppressed, !reasons.isEmpty else { return }
        step = .collection
        shown = true
    }

    /// Sheet sichtbar? In Ende-zu-Ende-Läufen nie (der Zustand bleibt über die Steuerung lesbar)
    var sheetShown: Bool { shown && !E2E.isActive }

    /// Menü „Einrichtung …“ und E2E: Sheet öffnen (auch wenn unterdrückt)
    func open(_ s: Step = .collection) {
        step = s
        shown = true
    }

    /// Weiter / Fertig / Schließen: Einstellungen sichern, damit der Erststart nicht wiederkommt
    func close() {
        shown = false
        mix?.prefs.save()
    }

    /// Schritt Collection: gewählte Datei merken und laden (der Datenordner wechselt beim nächsten Start)
    func chooseCollection(_ url: URL, store: LibraryStore) {
        LibraryStore.chosenNML = url
        mix?.prefs.ui.collectionPath = url.path
        store.load(url)
    }

    /// Google Drive: Musik-Ordner, die schon da sind (`My Drive/Music` oder `My Drive/Musik`)
    static func driveMusicFolders() -> [String] {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)) ?? []
        var out: [String] = []
        for d in dirs.sorted(by: { $0.path < $1.path }) where d.lastPathComponent.hasPrefix("GoogleDrive-") {
            for name in ["Music", "Musik"] {
                let u = d.appendingPathComponent("My Drive", isDirectory: true).appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: u.path) { out.append(u.path) }
            }
        }
        return out
    }

    /// Für den Schritt Musik: Ordner dazunehmen (wie in den Einstellungen; der automatische bleibt dabei)
    func addMusicFolders(_ paths: [String], store: LibraryStore) {
        guard let mix else { return }
        var list = mix.prefs.ui.musicFolders
        if list.isEmpty, let d = store.folders.defaultRoot { list = [d] }
        for p in paths where !list.contains(p) { list.append(p) }
        mix.prefs.ui.musicFolders = list
    }

    var deviceMissing: Bool {
        guard let mix, let uid = mix.deviceUID else { return false }
        return !mix.outputDevices.contains { $0.uid == uid }
    }
}

/// Das Sheet: ein Schritt nach dem anderen, Kopf mit Nummer, Fuß mit Zurück / Überspringen / Weiter
struct SetupFlowView: View {
    @Environment(MixModel.self) private var mix
    @Environment(LibraryStore.self) private var store
    private var flow: SetupFlow { SetupFlow.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14.z) {
            HStack {
                Text("EINRICHTUNG · SCHRITT \(flow.step.number) VON \(SetupFlow.Step.allCases.count)")
                    .font(Theme.mono(10.z)).foregroundStyle(Theme.bone.opacity(0.6))
                Spacer()
            }
            Text(title).font(Theme.label(15.z))
            Group {
                switch flow.step {
                case .collection: collectionStep
                case .music: musicStep
                case .audio: audioStep
                case .network: networkStep
                case .done: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(18.z)
        .frame(width: 560.z)
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }

    private var title: String {
        switch flow.step {
        case .collection: String(localized: "Collection")
        case .music: String(localized: "Musik")
        case .audio: String(localized: "Ausgabe")
        case .network: String(localized: "Netzwerk")
        case .done: String(localized: "Fertig")
        }
    }

    // MARK: Schritte

    private var collectionStep: some View {
        VStack(alignment: .leading, spacing: 10.z) {
            Text("MINOS-741 liest die Collection (collection.nml) deiner DJ-Software. Ohne sie zeigt das Fenster nur die Musik-Ordner.")
                .fixedSize(horizontal: false, vertical: true)
            if let c = LibraryStore.chosenNML, FileManager.default.fileExists(atPath: c.path) {
                Text("Gewählt: \(c.path)").font(Theme.mono(10.z)).lineLimit(2).truncationMode(.middle)
            } else if FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path) {
                Text("Gefunden: \(LibraryStore.defaultNML.path)").font(Theme.mono(10.z)).lineLimit(2).truncationMode(.middle)
            } else {
                Text("Keine Collection gefunden.").font(Theme.mono(10.z)).foregroundStyle(Theme.state)
            }
            HStack {
                Button("Collection wählen …") { chooseCollection() }
                Spacer()
            }
            Text("Der Datenordner (Einstellungen, Verlauf) liegt dann neben dieser Datei. Er wird beim nächsten Start benutzt.")
                .settingsHint()
        }
    }

    private var musicStep: some View {
        let drive = SetupFlow.driveMusicFolders()
        return VStack(alignment: .leading, spacing: 10.z) {
            Text("Musik-Ordner: hier suchen die Browser nach Dateien, die nicht in der Collection stehen.")
                .fixedSize(horizontal: false, vertical: true)
            let roots = store.folders.roots
            if mix.prefs.ui.musicFolders.isEmpty {
                Text("Automatisch: \(store.folders.defaultRoot ?? "–")").font(Theme.mono(10.z)).lineLimit(1).truncationMode(.middle)
            }
            ForEach(roots, id: \.self) { p in
                Text(verbatim: p).font(Theme.mono(10.z)).lineLimit(1).truncationMode(.middle)
            }
            ForEach(drive.filter { !roots.contains($0) }, id: \.self) { p in
                HStack {
                    Text("Google Drive: \(p)").font(Theme.mono(10.z)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Hinzufügen") { flow.addMusicFolders([p], store: store) }
                }
            }
            HStack {
                Button("Ordner hinzufügen …") { addFolders() }
                Spacer()
            }
        }
    }

    private var audioStep: some View {
        VStack(alignment: .leading, spacing: 10.z) {
            Text("Ausgabegerät und Mixer-Modus. Die Werte sind dieselben wie unter AUDIO in den Einstellungen.")
                .fixedSize(horizontal: false, vertical: true)
            if flow.deviceMissing {
                Text("Das gespeicherte Gerät ist nicht angeschlossen. Anschließen oder „Systemstandard“ wählen.")
                    .foregroundStyle(Theme.state).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                AudioDevicePicker()
                MixerModePicker()
            }
            .formStyle(SettingsFormStyle())
            Text(mix.engineStatus).settingsHint()
        }
    }

    private var networkStep: some View {
        VStack(alignment: .leading, spacing: 10.z) {
            Text("Der Zwei-Mac-Modus und Link finden den anderen Rechner im lokalen Netz. macOS fragt dafür einmal nach der Berechtigung „Lokales Netzwerk“. Wurde sie abgelehnt, lässt sie sich nur in den Systemeinstellungen wieder einschalten.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Systemeinstellungen öffnen …") {
                    if let u = URL(string: SetupFlow.privacyLocalNetwork) { NSWorkspace.shared.open(u) }
                }
                Spacer()
            }
        }
    }

    private var doneStep: some View {
        let collection = LibraryStore.chosenNML.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil }
            ?? (FileManager.default.fileExists(atPath: LibraryStore.defaultNML.path) ? LibraryStore.defaultNML.path : nil)
        return VStack(alignment: .leading, spacing: 6.z) {
            summary("Collection", collection ?? String(localized: "keine – nur Musik-Ordner"))
            summary("Musik-Ordner", "\(mix.prefs.ui.musicFolders.isEmpty ? 1 : mix.prefs.ui.musicFolders.count)")
            summary("Gerät", mix.currentDevice?.name ?? String(localized: "Systemstandard"))
            summary("Mixer", mix.mixerMode == .internalMixer ? String(localized: "Intern") : String(localized: "Extern"))
            Text("Alles lässt sich unter ⌘, ändern. Diese Einrichtung öffnet das Menü „Einrichtung …“.").settingsHint()
                .padding(.top, 6.z)
        }
    }

    private func summary(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(Theme.label(10.z)).frame(width: 130.z, alignment: .leading)
            Text(verbatim: v).font(Theme.mono(10.z)).lineLimit(2).truncationMode(.middle)
            Spacer()
        }
    }

    // MARK: Fuß

    private var footer: some View {
        let steps = SetupFlow.Step.allCases
        let i = steps.firstIndex(of: flow.step) ?? 0
        let last = flow.step == .done
        return HStack(spacing: 8.z) {
            if i > 0 { Button("Zurück") { flow.step = steps[i - 1] } }
            Spacer()
            if !last {
                Button(flow.step == .collection ? "Ohne Collection weiter" : "Überspringen") { flow.step = steps[i + 1] }
            }
            if last {
                Button("Fertig") { flow.close() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Weiter") { flow.step = steps[i + 1] }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Aktionen

    private func chooseCollection() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "nml") ?? .data]
        panel.message = String(localized: "Collection-Datei wählen (collection.nml)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        flow.chooseCollection(url, store: store)
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let d = store.folders.roots.first { panel.directoryURL = URL(fileURLWithPath: d) }
        guard panel.runModal() == .OK else { return }
        flow.addMusicFolders(panel.urls.map(\.path), store: store)
    }
}
