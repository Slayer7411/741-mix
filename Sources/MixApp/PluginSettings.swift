import SwiftUI
import AppKit
import AudioToolbox
import MixEngine

/// Plugin-Verwaltung für die Oberfläche: Liste, Ordner, Installieren, Prüfen (auval, VST3-Selbsttest). Die Daten liegen im PluginCatalog
/// des Kerns – das FX-Menü sieht dieselbe Liste.
@MainActor @Observable
final class PluginManager {
    @ObservationIgnored let catalog: PluginCatalog
    private(set) var entries: [PluginEntry] = []
    private(set) var settings: PluginSettings
    private(set) var scanning = false
    /// laufende Prüfung (Plugin-ID) und Fortschritt von „Alle prüfen“
    private(set) var validating: String?
    private(set) var progress: (done: Int, total: Int)?
    /// Ergebnis der letzten Installation
    var message: String?

    /// VST3-Selbsttest im eigenen Prozess: dieses Programm mit --vst3-check
    @ObservationIgnored private let validator = PluginValidator(selfCheckExecutable: Bundle.main.executableURL)
    @ObservationIgnored private var validateAllTask: Task<Void, Never>?
    @ObservationIgnored private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    @ObservationIgnored private var rescanPending = false
    @ObservationIgnored private var registrationObserver: NSObjectProtocol?

    init(catalog: PluginCatalog) {
        self.catalog = catalog
        settings = catalog.settings
        rescan()
        // Systemregister geändert (Plugin installiert/entfernt, App mit AUv3 dazu) → neu einlesen
        let name = NSNotification.Name(kAudioComponentRegistrationsChangedNotification as String)
        registrationObserver = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
    }

    // MARK: Liste

    func rescan() {
        scanning = true
        let c = catalog
        Task.detached(priority: .userInitiated) {
            let e = c.entries(refresh: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.entries = e
                self.settings = c.settings
                self.scanning = false
                self.updateWatchers()
            }
        }
    }

    /// Änderungen bündeln (Kopieren eines Bundles löst viele Ereignisse aus)
    func scheduleRescan(after s: Double = 1) {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            MainActor.assumeIsolated {
                self?.rescanPending = false
                self?.rescan()
            }
        }
    }

    /// eigene Ordner und den Benutzer-Ordner beobachten: neue/entfernte Bundles → neu einlesen
    private func updateWatchers() {
        let want = Set(settings.folders + [PluginInstaller.userComponents.path, PluginInstaller.userVST3.path])
        for (p, src) in watchers where !want.contains(p) { src.cancel(); watchers[p] = nil }
        for p in want where watchers[p] == nil {
            let fd = open(p, O_EVTONLY)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.scheduleRescan() } }
            src.setCancelHandler { close(fd) }
            src.resume()
            watchers[p] = src
        }
    }

    private func changed() { settings = catalog.settings }

    func setEnabled(_ e: PluginEntry, _ on: Bool) { catalog.setEnabled(e.id, on); changed() }
    func setIsolation(_ e: PluginEntry, _ on: Bool?) { catalog.setIsolation(e.id, on); changed() }
    func setIsolateThirdParty(_ on: Bool) { catalog.update { $0.isolateThirdParty = on }; changed() }
    func setAllowInProcess(_ on: Bool) { catalog.update { $0.allowInProcess = on }; changed() }
    func unblock(_ key: String) { catalog.unblock(key); changed(); rescan() }

    /// isoliert laden (Einstellung je Plugin oder Standard)
    func isolated(_ e: PluginEntry) -> Bool { PluginCatalog.isolated(e, settings) }
    /// nur im Prozess ladbar und das nicht erlaubt (live gesperrt)
    func inProcessOnly(_ e: PluginEntry) -> Bool { PluginCatalog.inProcessOnly(e, settings) }

    // MARK: Ordner

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Ordner mit .component- oder .vst3-Bundles (Unterordner werden mit eingelesen)")
        guard panel.runModal() == .OK else { return }
        catalog.update { s in for u in panel.urls where !s.folders.contains(u.path) { s.folders.append(u.path) } }
        changed()
        rescan()
    }

    func removeFolder(_ p: String) {
        catalog.update { $0.folders.removeAll { $0 == p } }
        changed()
        rescan()
    }

    // MARK: Installieren

    /// .component-Bundles (oder Ordner/.zip damit) nach ~/Library/Audio/Plug-Ins/Components kopieren, .vst3 nach …/VST3 –
    /// nur auf Klick
    func install() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = String(localized: "Installieren")
        panel.message = String(localized: ".component- oder .vst3-Bundles, Ordner oder .zip wählen")
        guard panel.runModal() == .OK else { return }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("minos-install-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: scratch) }
        let found: (components: [URL], vst3: [URL])
        do { found = try PluginInstaller.collect(panel.urls, scratch: scratch) } catch {
            message = error.localizedDescription; return
        }
        var lines: [String] = []
        if found.components.isEmpty && found.vst3.isEmpty { message = String(localized: "keine .component- oder .vst3-Bundles gefunden"); return }

        var clearQuarantine = false
        if (found.components + found.vst3).contains(where: PluginInstaller.isQuarantined) {
            let a = NSAlert()
            a.messageText = String(localized: "Quarantäne-Markierung entfernen?")
            a.informativeText = String(localized: "Die Auswahl stammt aus einem Download. Gatekeeper kann nicht signierte oder nicht beglaubigte Plugins dann beim Laden blockieren. Nur entfernen, wenn du der Quelle vertraust.")
            a.addButton(withTitle: String(localized: "Entfernen"))
            a.addButton(withTitle: String(localized: "Behalten"))
            clearQuarantine = a.runModal() == .alertFirstButtonReturn
        }
        let jobs = found.components.map { ($0, PluginInstaller.userComponents) } + found.vst3.map { ($0, PluginInstaller.userVST3) }
        for (b, dest) in jobs {
            let name = b.deletingPathExtension().lastPathComponent
            if let c = PluginInstaller.conflict(b, in: dest), !c.sameVersion {
                let a = NSAlert()
                a.messageText = String(format: String(localized: "„%@“ ist schon installiert"), name)
                a.informativeText = String(format: String(localized: "Installiert: %@ · neu: %@. Ersetzen?"),
                                           c.oldVersion.isEmpty ? "?" : c.oldVersion, c.newVersion.isEmpty ? "?" : c.newVersion)
                a.addButton(withTitle: String(localized: "Ersetzen"))
                a.addButton(withTitle: String(localized: "Überspringen"))
                guard a.runModal() == .alertFirstButtonReturn else {
                    lines.append(String(format: String(localized: "übersprungen: %@"), name)); continue
                }
            }
            do {
                let t = try PluginInstaller.install(b, into: dest)
                if clearQuarantine { PluginInstaller.clearQuarantine(t) }
                lines.append(String(format: String(localized: "installiert: %@"), name))
            } catch {
                lines.append("\(name): \(error.localizedDescription)")
            }
        }
        message = lines.joined(separator: "\n")
        // das Systemregister braucht einen Moment für neue Bundles
        scheduleRescan(after: 1.5)
    }

    // MARK: Prüfen (auval, VST3-Selbsttest)

    func validate(_ e: PluginEntry) {
        guard validating == nil, progress == nil, e.canValidate else { return }
        validateAllTask = Task { await runValidation(e) }
    }

    private func runValidation(_ e: PluginEntry) async {
        guard let info = e.info else { return }
        validating = e.id
        let r = await validator.run(info)
        validating = nil
        catalog.storeValidation(e, r)
        changed()
    }

    func validateAll() {
        guard validating == nil, progress == nil else { return }
        let list = entries.filter(\.canValidate)
        validator.reset()
        progress = (0, list.count)
        validateAllTask = Task {
            for (i, e) in list.enumerated() {
                if Task.isCancelled { break }
                await runValidation(e)
                progress = (i + 1, list.count)
            }
            progress = nil
            validator.reset()
        }
    }

    func cancelValidation() {
        validateAllTask?.cancel()
        validator.cancel()
    }
}

// MARK: - Seite

/// Einstellungen → PLUGINS
struct PluginSettingsView: View {
    @Environment(MixModel.self) private var mix

    var body: some View { PluginSettingsPage(pm: mix.plugins) }
}

/// Inhalt des Tabs; das Selbsttest-Bild nutzt ihn ohne MixModel (kein Audio) und gibt Suche + aufgeklappte Zeile vor
struct PluginSettingsPage: View {
    let pm: PluginManager
    @State var search = ""
    @State var expanded: String?

    var body: some View {
        let s = pm.settings
        Form {
            Section("Laden") {
                Toggle("Plugins im Prozess (riskant)", isOn: Binding(get: { s.allowInProcess }, set: { pm.setAllowInProcess($0) }))
                Text("aus (standard, live): audio units anderer hersteller laufen nur isoliert in einem eigenen systemdienst. stürzt eins ab oder antwortet nicht, läuft minos weiter, die fx-unit bleibt trocken, das plugin lädt nach 2 s neu und ist nach 3 abstürzen blockiert. vst3 und plugins aus eigenen ordnern laufen nur im prozess und werden nicht geladen. an: auch im prozess – ein absturz des plugins beendet minos, ein hänger stoppt den ton. apple-plugins laufen immer im prozess. gilt ab dem nächsten laden des plugins.")
                    .settingsHint()
                if s.allowInProcess {
                    Toggle("Drittanbieter-Plugins isoliert laden", isOn: Binding(get: { s.isolateThirdParty }, set: { pm.setIsolateThirdParty($0) }))
                    Text("isoliert kostet je block etwas zeit (siehe handbuch). der dienst kennt nur installierte audio units, vst3 und eigene ordner laufen immer im prozess.")
                        .settingsHint()
                }
                if let c = pm.catalog.crashedLastRun {
                    Text(String(format: String(localized: "beim letzten lauf beim öffnen abgestürzt: %@ -> blockiert"), c.name))
                        .font(Theme.mono(10)).foregroundStyle(Theme.state)
                }
            }
            Section("Ordner") {
                folderRow("◆", PluginCatalog.defaultFolders[0].0.path, "System")
                folderRow("◆", "~/Library/Audio/Plug-Ins/Components", "Benutzer")
                folderRow("◆", String(localized: "AUv3 aus Apps (Systemregister)"), "App")
                folderRow("◆", PluginCatalog.defaultVST3Folders[0].path, "VST3")
                folderRow("◆", "~/Library/Audio/Plug-Ins/VST3", "VST3")
                ForEach(s.folders, id: \.self) { p in
                    HStack(spacing: 8) {
                        Text(verbatim: "◇").font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 12)
                        Text(verbatim: p).font(Theme.mono(10)).lineLimit(1).truncationMode(.middle).help(p)
                        Spacer(minLength: 8)
                        Button("Entfernen") { pm.removeFolder(p) }
                    }
                }
                HStack(spacing: 8) {
                    Button("Ordner hinzufügen …") { pm.addFolders() }
                    Button("Plugin installieren …") { pm.install() }
                    Button("Neu einlesen") { pm.rescan() }
                    if pm.scanning { Text("liest …").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                }
                .padding(.top, 4)
                Text("installieren kopiert .component-bundles (auch aus ordnern oder .zip) nach ~/Library/Audio/Plug-Ins/Components, .vst3 nach ~/Library/Audio/Plug-Ins/VST3, nie in den system-ordner. nicht signierte oder nicht beglaubigte plugins kann gatekeeper blockieren; die quarantäne-markierung aus dem download wird nur nach rückfrage entfernt. eigene ordner: bundles werden nur in minos geladen und registriert, nicht installiert.")
                    .settingsHint()
                if let m = pm.message {
                    Text(verbatim: m).font(Theme.mono(10)).foregroundStyle(Theme.bone)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                HStack(spacing: 8) {
                    TextField("Suchen", text: $search).settingsField().frame(maxWidth: 220)
                    Spacer(minLength: 8)
                    if let p = pm.progress {
                        Text(verbatim: "\(p.done)/\(p.total)").font(Theme.mono(10)).monospacedDigit().foregroundStyle(Theme.muted)
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1))).frame(width: 80)
                    }
                    if pm.progress != nil || pm.validating != nil {
                        Button("Abbrechen") { pm.cancelValidation() }
                    } else {
                        Button("Alle prüfen") { pm.validateAll() }.help("auval für jedes installierte Audio-Unit-Plugin, Selbsttest für jedes VST3")
                    }
                }
                .padding(.bottom, 4)
                let list = filtered(pm.entries)
                if list.isEmpty {
                    Text(LocalizedStringKey(pm.scanning ? "liest …" : "keine plugins gefunden")).settingsHint()
                }
                ForEach(list) { e in
                    PluginRow(entry: e, pm: pm, expanded: expanded == e.id) { expanded = expanded == e.id ? nil : e.id }
                }
            } header: {
                Text(String(format: String(localized: "Plugins · %lld"), pm.entries.count))
            }
        }
    }

    private func filtered(_ all: [PluginEntry]) -> [PluginEntry] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { e in
            let hay = "\(e.name) \(e.manufacturer) \(e.format.rawValue) \(e.id)".lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }

    private func folderRow(_ glyph: String, _ path: String, _ kind: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: glyph).font(Theme.mono(10)).foregroundStyle(Theme.muted).frame(width: 12)
            Text(verbatim: path).font(Theme.mono(10)).foregroundStyle(Theme.bone.opacity(0.8)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(kind).font(Theme.label(9, .bold)).textCase(.uppercase).foregroundStyle(Theme.muted)
        }
    }
}

/// eine Zeile: an/aus · Name, Hersteller · Version · Format · Herkunft · Status · PRÜFEN; Klick klappt Details auf
private struct PluginRow: View {
    let entry: PluginEntry
    let pm: PluginManager
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        let e = entry
        let loadable = e.info != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                SquareCheck(on: loadable && !pm.settings.disabled.contains(e.id), enabled: loadable) { pm.setEnabled(e, $0) }
                    .help("in MINOS-741 verwenden (FX-Menü)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: e.name).font(Theme.mono(11, .medium)).foregroundStyle(loadable ? Theme.bone : Theme.muted).lineLimit(1)
                    Text(verbatim: meta(e)).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if e.foreignArch {
                    StatusBadge(status: .init(text: e.canIsolate ? String(localized: "nur Intel – isoliert") : String(localized: "nur Intel – nicht ladbar"),
                                              alert: !e.canIsolate, strong: false))
                        .help(e.canIsolate ? Text("nur Intel – läuft nur isoliert/unter Rosetta") : Text("nur Intel – VST3 nicht ladbar"))
                }
                if pm.inProcessOnly(e) {
                    StatusBadge(status: .init(text: String(localized: "nur im Prozess – aus"), alert: true, strong: false))
                        .help("läuft nur im Prozess von MINOS-741 – wird erst mit „Plugins im Prozess (riskant)“ geladen")
                } else if e.format == .vst3 && loadable {
                    StatusBadge(status: .init(text: String(localized: "läuft im Prozess"), alert: false, strong: false))
                        .help("VST3 läuft im Prozess von MINOS-741 (isolieren geht nur für Audio Units)")
                }
                StatusBadge(status: status(e))
                if e.canValidate {
                    Button(LocalizedStringKey(pm.validating == e.id ? "prüft …" : "Prüfen")) { pm.validate(e) }
                        .disabled(pm.validating != nil || pm.progress != nil)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if expanded { details(e) }
        }
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline.opacity(0.5)).frame(height: 1).offset(y: 5) }
    }

    @ViewBuilder private func details(_ e: PluginEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: e.path ?? e.id).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
            if e.canIsolate && pm.settings.allowInProcess {
                HStack(spacing: 8) {
                    Text("Laden").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    Picker("Laden", selection: Binding(get: { pm.settings.isolation[e.id].map { $0 ? 1 : 2 } ?? 0 },
                                                       set: { pm.setIsolation(e, $0 == 0 ? nil : $0 == 1) })) {
                        Text(LocalizedStringKey(pm.isolated(e) && pm.settings.isolation[e.id] == nil ? "Standard (isoliert)" : "Standard (im Prozess)")).tag(0)
                        Text("Isoliert").tag(1)
                        Text("Im Prozess").tag(2)
                    }
                    .labelsHidden().frame(width: 190)
                }
            } else if e.canIsolate {
                Text(LocalizedStringKey(pm.isolated(e) ? "läuft isoliert (plugins im prozess: aus)" : "apple: läuft im prozess"))
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted)
            } else if e.format == .vst3 && e.info != nil {
                Text("vst3: läuft im prozess (isolieren geht nur für audio units). stürzt es beim öffnen ab, ist es beim nächsten start blockiert.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else if e.info != nil {
                Text("eigener ordner: läuft im prozess (isolieren geht nur für installierte)").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
            if let n = pm.settings.crashes[e.id], n > 0, pm.settings.blocked[e.id] == nil {
                Text(String(format: String(localized: "isoliert abgestürzt: %lld von %lld (danach blockiert)"), n, PluginCatalog.crashLimit))
                    .font(Theme.mono(10)).foregroundStyle(Theme.state)
            }
            if let r = pm.settings.blocked[e.id] {
                HStack(spacing: 8) {
                    Text(verbatim: r).font(Theme.mono(10)).foregroundStyle(Theme.state)
                    Button("Block aufheben") { pm.unblock(e.id) }
                }
            }
            if let p = e.problem { Text(verbatim: p).font(Theme.mono(10)).foregroundStyle(Theme.state) }
            if let v = pm.catalog.validation(e) {
                Text(verbatim: (e.format == .vst3 ? String(localized: "selbsttest") : "auval") + " · " + Theme.date(v.date) + "\n" + v.log)
                    .font(Theme.mono(9)).foregroundStyle(v.passed ? Theme.bone.opacity(0.75) : Theme.state)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.void)
                    .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            } else if !e.canValidate && e.info != nil {
                Text("auval prüft nur installierte plugins").font(Theme.mono(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }

    private func meta(_ e: PluginEntry) -> String {
        let src: String
        switch e.source {
        case .system: src = String(localized: "System")
        case .user: src = String(localized: "Benutzer")
        case .folder: src = String(localized: "eigener Ordner")
        case .appExtension: src = String(localized: "App")
        }
        let iso = pm.isolated(e) ? " · " + String(localized: "isoliert") : ""
        return [e.manufacturer, e.version, e.format.rawValue, src].filter { !$0.isEmpty }.joined(separator: " · ") + iso
    }

    private func status(_ e: PluginEntry) -> StatusBadge.Status {
        if pm.settings.blocked[e.id] != nil { return .init(text: String(localized: "blockiert"), alert: true, strong: true) }
        if e.problem != nil { return .init(text: String(localized: "nicht ladbar"), alert: true, strong: true) }
        if let v = pm.settings.validation[e.validationKey] {
            return v.passed ? .init(text: "ok", alert: false, strong: true)
                : .init(text: String(localized: "prüfung fehlgeschlagen"), alert: true, strong: true)
        }
        return .init(text: String(localized: "ungeprüft"), alert: false, strong: false)
    }
}

/// Status-Etikett (741: dunkel mit Haarlinie, Fehler rot)
private struct StatusBadge: View {
    struct Status { let text: String; let alert: Bool; let strong: Bool }
    let status: Status

    var body: some View {
        Text(verbatim: status.text)
            .font(Theme.label(9, .bold)).textCase(.uppercase).lineLimit(1)
            .foregroundStyle(status.alert ? Theme.state : (status.strong ? Theme.bone : Theme.muted))
            .padding(.horizontal, 6).frame(height: 16)
            .background(Theme.void)
            .overlay(Rectangle().stroke(status.alert ? Theme.state : Theme.hairline, lineWidth: 1))
            .fixedSize()
    }
}

/// Quadrat-Schalter ohne Beschriftung (wie die Schalter der Einstellungen)
private struct SquareCheck: View {
    let on: Bool
    let enabled: Bool
    let set: (Bool) -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.void)
            Rectangle().stroke(on ? Theme.state : Theme.muted.opacity(enabled ? 1 : 0.4), lineWidth: 1)
            if on { Rectangle().fill(Theme.state).padding(3) }
        }
        .frame(width: 14, height: 14)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { set(!on) } }
        .accessibilityAddTraits(.isButton)
    }
}
