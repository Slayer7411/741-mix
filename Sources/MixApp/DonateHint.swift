import AppKit
import SwiftUI
import MixCore

/// Spenden-Hinweis beim Start: Bier oder ein paar Tokens, PayPal mit freiem Betrag. Weg ist er erst mit `donated`
/// (Zahlung dieser Instanz, Kennung `code` reist als item_number mit); `scripts/make-app.sh` setzt beim Installieren `donated` (die eigene Installation
/// zeigt ihn nie). Nicht im Selbsttest. Schlüssel in UserDefaults, nicht in den Prefs (Profile kopieren ihn sonst mit).
enum DonateHint {
    static let mail = "money@blackgrey.de"
    /// Kennung dieser Installation (8 Hex): geht als item_number / custom mit zu PayPal, damit eine spätere Prüfung
    /// die Zahlung dieser Instanz zuordnen kann
    static var code: String {
        if let c = E2E.defaults.string(forKey: "donateCode"), c.count == 8 { return c }
        let c = String(format: "%08x", UInt32.random(in: 0...UInt32.max))
        E2E.defaults.set(c, forKey: "donateCode")
        return c
    }
    static var url: URL {
        URL(string: "https://www.paypal.com/donate/?business=money%40blackgrey.de&currency_code=EUR&item_name=MINOS-741%20beer%20%2F%20tokens&item_number=\(code)&custom=\(code)")!
    }

    enum Mode: String, CaseIterable, Identifiable {
        case always, weekly, never   // never: nur noch über `donated` erreichbar (Zahlung), nicht wählbar
        var id: String { rawValue }
        static let selectable: [Mode] = [.always, .weekly]
        var title: String {
            switch self {
            case .always: String(localized: "bei jedem Start")
            case .weekly: String(localized: "einmal pro Woche")
            case .never: String(localized: "nie")
            }
        }
    }

    static var mode: Mode {
        get { Mode(rawValue: E2E.defaults.string(forKey: "donateHint") ?? "") ?? .always }
        set { E2E.defaults.set(newValue.rawValue, forKey: "donateHint") }
    }
    static var donated: Bool {
        get { E2E.defaults.bool(forKey: "donated") }
        set { E2E.defaults.set(newValue, forKey: "donated") }
    }
    static var lastShown: Date? {
        get { E2E.defaults.object(forKey: "donateLast") as? Date }
        set { E2E.defaults.set(newValue, forKey: "donateLast") }
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

    static var dueNow: Bool { !Session.isSelfTest && !E2E.isActive && due(mode: mode, donated: donated, lastShown: lastShown) }

    static func open() { NSWorkspace.shared.open(url) }
}

struct DonateView: View {
    @Binding var shown: Bool
    @State private var mode = DonateHint.mode == .never ? .always : DonateHint.mode

    var body: some View {
        VStack(alignment: .leading, spacing: 14.z) {
            Text("BUY ME A BEER 🍺 … ODER EIN PAAR TOKENS").font(Theme.label(15.z))
            Text("MINOS-741 entsteht nachts: aus Kaffee, Bier und einer beängstigenden Menge KI-Tokens. Keine Firma, kein Abo, kein Tracking, kein Investor, der ein Dashboard will.\n\nWenn dir die App ein Set gerettet hat: Gib einen aus. Ein Bier für mich oder ein paar Tokens für den nächsten Bug, der vor deinem Gig sterben soll. Betrag frei, PayPal an \(DonateHint.mail).")
                .font(Theme.mono(11.z))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.z) {
                Button("🍺 EINEN AUSGEBEN") { DonateHint.open(); shown = false }
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Button("SPÄTER, BIN IM MIX") { shown = false }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6.z) {
                Text("Nerven lassen:").font(Theme.mono(10.z)).foregroundStyle(Theme.bone.opacity(0.7))
                Picker("", selection: $mode) { ForEach(DonateHint.Mode.selectable) { Text($0.title).tag($0) } }
                    .labelsHidden().fixedSize()
                    .onChange(of: mode) { DonateHint.mode = mode }
                Spacer()
                Text("Instanz \(DonateHint.code)").font(Theme.mono(9.z)).foregroundStyle(Theme.bone.opacity(0.4))
            }
        }
        .padding(18.z)
        .frame(width: 460.z)
        .background(Theme.background)
        .foregroundStyle(Theme.bone)
        .tint(Theme.state)
    }
}
