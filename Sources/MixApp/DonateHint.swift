import AppKit
import SwiftUI

/// Spenden-Hinweis beim Start: Kaffee oder ein paar Tokens, PayPal mit freiem Betrag. Einmal „Ich habe gespendet“ oder
/// „Nie“ und er kommt nicht wieder; `scripts/make-app.sh` setzt beim Installieren `donated` (die eigene Installation
/// zeigt ihn nie). Nicht im Selbsttest. Schlüssel in UserDefaults, nicht in den Prefs (Profile kopieren ihn sonst mit).
enum DonateHint {
    static let url = URL(string: "https://www.paypal.com/donate/?business=money%40blackgrey.de&currency_code=EUR&item_name=MINOS-741")!
    static let mail = "money@blackgrey.de"

    enum Mode: String, CaseIterable, Identifiable {
        case always, weekly, never
        var id: String { rawValue }
        var title: String {
            switch self {
            case .always: String(localized: "bei jedem Start")
            case .weekly: String(localized: "einmal pro Woche")
            case .never: String(localized: "nie")
            }
        }
    }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: "donateHint") ?? "") ?? .always }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "donateHint") }
    }
    static var donated: Bool {
        get { UserDefaults.standard.bool(forKey: "donated") }
        set { UserDefaults.standard.set(newValue, forKey: "donated") }
    }
    static var lastShown: Date? {
        get { UserDefaults.standard.object(forKey: "donateLast") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "donateLast") }
    }

    /// Hinweis fällig? Reine Regel für den Test: nie nach einer Spende oder bei „nie“, wöchentlich = 7 Tage seit dem letzten Mal
    static func due(mode: Mode, donated: Bool, lastShown: Date?, now: Date = Date()) -> Bool {
        if donated { return false }
        switch mode {
        case .never: return false
        case .always: return true
        case .weekly: return lastShown.map { now.timeIntervalSince($0) >= 7 * 86400 } ?? true
        }
    }

    static var dueNow: Bool { !Session.isSelfTest && due(mode: mode, donated: donated, lastShown: lastShown) }

    static func open() { NSWorkspace.shared.open(url) }
}

struct DonateView: View {
    @Binding var shown: Bool
    @State private var mode = DonateHint.mode

    var body: some View {
        VStack(alignment: .leading, spacing: 14.z) {
            Text("KAUF MIR EINEN KAFFEE ☕").font(Theme.label(15.z))
            Text("… oder ein paar Claude-Tokens, damit MINOS-741 besser wird. Betrag frei wählbar, PayPal an \(DonateHint.mail).")
                .font(Theme.mono(11.z))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.z) {
                Button("Spenden (PayPal)") { DonateHint.open(); DonateHint.donated = true; shown = false }
                    .keyboardShortcut(.defaultAction)
                Button("Ich habe gespendet") { DonateHint.donated = true; shown = false }
                Spacer()
                Button("Später") { shown = false }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6.z) {
                Text("Hinweis zeigen:").font(Theme.mono(10.z)).foregroundStyle(Theme.bone.opacity(0.7))
                Picker("", selection: $mode) { ForEach(DonateHint.Mode.allCases) { Text($0.title).tag($0) } }
                    .labelsHidden().fixedSize()
                    .onChange(of: mode) { DonateHint.mode = mode }
            }
        }
        .padding(18.z)
        .frame(width: 440.z)
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }
}
