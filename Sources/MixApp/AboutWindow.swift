import AppKit
import SwiftUI
import MixCore

/// Angaben für „Über MINOS-741“: Version, Codename, Build, Datum und die mitgelieferten Komponenten mit Lizenz.
/// Reine Daten (Info-Wörterbuch als Eingabe), damit sie ohne Fenster prüfbar sind
struct AboutInfo: Equatable {
    struct Component: Identifiable, Equatable {
        let name: String
        let version: String
        let licence: String
        /// Lizenztext im Ressourcen-Ordner (`Resources/<file>`), vollständig angezeigt
        let file: String
        var note: String?
        var id: String { name }
    }

    let version: String
    let codename: String
    /// Build-Kennung (kurzer Git-Hash im Release-Bündel, sonst „dev“)
    let build: String
    /// Baudatum als JJJJ-MM-TT, leer ohne Bündel
    let buildDate: String

    var versionLine: String { [version, codename].filter { !$0.isEmpty }.joined(separator: " · ") }
    var buildLine: String { ["build \(build)", buildDate].filter { !$0.isEmpty }.joined(separator: " · ") }

    /// MINOS-741 selbst, mitgelieferter Fremdcode und Schriften; Lizenztexte liegen in `Resources/Licenses` bzw. `Resources/Fonts`
    static func components(appVersion: String) -> [Component] { [
        Component(name: "MINOS-741", version: appVersion, licence: "GPL-2.0-or-later", file: "Licenses/LICENSE-MINOS-741.md"),
        Component(name: "link library", version: "3.1.5", licence: "GPL-2.0-or-later", file: "Licenses/LICENSE-link.md"),
        Component(name: "Asio (in link library)", version: "", licence: "Boost Software License 1.0", file: "Licenses/LICENSE-asio.txt"),
        Component(name: "VST 3 SDK (hosting part)", version: "3.8.1 build 84", licence: "MIT", file: "Licenses/LICENSE-VST3SDK.txt",
                  note: "VST is a registered trademark of Steinberg Media Technologies GmbH. MINOS-741 is not affiliated with or endorsed by Steinberg."),
        Component(name: "signalsmith-stretch", version: "1.4.0", licence: "MIT", file: "Licenses/LICENSE-signalsmith-stretch.txt"),
        Component(name: "signalsmith-linear", version: "146b26f", licence: "MIT", file: "Licenses/LICENSE-signalsmith-linear.txt"),
        Component(name: "Cinzel", version: "", licence: "SIL Open Font License 1.1", file: "Fonts/OFL-Cinzel.txt"),
        Component(name: "IBM Plex Mono", version: "", licence: "SIL Open Font License 1.1", file: "Fonts/OFL-IBMPlexMono.txt"),
    ] }

    /// Aus dem Info-Wörterbuch des Bündels (`Bundle.main.infoDictionary`); ohne Bündel (swift run) „dev“
    static func make(_ info: [String: Any]?) -> AboutInfo {
        let v = (info?["CFBundleShortVersionString"] as? String) ?? "dev"
        let b = (info?["CFBundleVersion"] as? String) ?? ""
        let codename = (info?["MINOSCodename"] as? String) ?? Codename.forVersion(v) ?? ""
        let date = (info?["MINOSBuildDate"] as? String).map { String($0.prefix(10)) } ?? ""
        return AboutInfo(version: v, codename: codename, build: b.isEmpty || b == v ? "dev" : b, buildDate: date)
    }

    /// Lizenztext einer Komponente (nil, wenn die Datei fehlt)
    static func licenceText(_ c: Component) -> String? {
        guard let u = AppResources.file(c.file) else { return nil }
        return try? String(contentsOf: u, encoding: .utf8)
    }
}

@MainActor
enum AboutWindow {
    static func show() {
        BasicWindows.show("about", title: "Über MINOS-741", size: NSSize(width: 580, height: 720)) {
            AnyView(AboutView(info: AboutInfo.make(Bundle.main.infoDictionary)))
        }
    }
}

struct AboutView: View {
    let info: AboutInfo
    @State private var open: String?

    /// Symbol der App aus den Ressourcen (im Entwicklungslauf sonst das allgemeine Programmsymbol)
    static var icon: NSImage {
        if let u = AppResources.file("AppIcon.png"), let img = NSImage(contentsOf: u) { return img }
        return NSApp.applicationIconImage ?? NSImage()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: AboutView.icon).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: "◆ MINOS-741").font(Theme.label(24)).textCase(.uppercase)
                    Text(verbatim: info.versionLine).font(Theme.mono(12)).foregroundStyle(Theme.bone)
                    Text(verbatim: info.buildLine).font(Theme.mono(11)).foregroundStyle(Theme.bone.opacity(0.7))
                    Text("made by 741").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 8) {
                DeckButton(title: "GitHub") { AppLinks.open(AppLinks.github) }
                DeckButton(title: "Instagram @minos_741") { AppLinks.open(AppLinks.instagram) }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Text("Lizenzen und Dank").font(Theme.label(13)).textCase(.uppercase)
            Text("Mitgelieferte Komponenten. Aufklappen zeigt den vollständigen Lizenztext aus dem Programm.")
                .font(Theme.mono(10)).foregroundStyle(Theme.bone.opacity(0.7))
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(AboutInfo.components(appVersion: info.version)) { c in
                        LicenceRow(component: c, expanded: open == c.id) {
                            open = open == c.id ? nil : c.id
                        }
                    }
                }
            }
            .background(Theme.chitin)
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }
}

/// Eine Komponente: Kopfzeile (Name, Version, Lizenz); aufgeklappt der volle Text, scrollbar
private struct LicenceRow: View {
    let component: AboutInfo.Component
    let expanded: Bool
    let toggle: () -> Void
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: expanded ? "▾" : "▸").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Text(verbatim: component.name).font(Theme.mono(12, .medium))
                if !component.version.isEmpty {
                    Text(verbatim: component.version).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Text(verbatim: component.licence).font(Theme.mono(10)).foregroundStyle(Theme.bone.opacity(0.8))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if expanded {
                if let n = component.note {
                    Text(verbatim: n).font(Theme.mono(10)).foregroundStyle(Theme.bone.opacity(0.7))
                }
                ScrollView {
                    Text(verbatim: text ?? String(localized: "Lizenztext fehlt im Programm"))
                        .font(Theme.mono(10))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(Theme.void)
                .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .task(id: expanded) {
            guard expanded, text == nil else { return }
            text = AboutInfo.licenceText(component)
        }
    }
}
