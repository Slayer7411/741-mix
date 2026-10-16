import SwiftUI
import MixCore

/// Auto-Mix im Mixer: Schalter (startet mit den Quellen der beiden Browser-Bereiche), Zustand mit dem nächsten Track,
/// STOP, SKIP und die nächsten drei. Im externen Modus gesperrt (Hinweis am Schalter).
struct AutoMixBar: View {
    @Environment(MixModel.self) private var mix

    var body: some View {
        let am = mix.autoMix
        let internalMode = mix.mixerMode == .internalMixer
        VStack(alignment: .leading, spacing: 4.z) {
            HStack(spacing: 6.z) {
                DeckButton(title: "AUTO-MIX", active: am.isOn, color: Theme.gold, width: 74, compact: true) {
                    if am.isOn { am.stop(String(localized: "Auto-Mix aus")) } else { am.startFromPanes() }
                }
                .disabled(!internalMode)
                .help(internalMode ? Text("Auto-Mix: wählt nach Match den nächsten Track aus den Quellen der beiden Bereiche und fährt den Übergang")
                               : Text("Auto-Mix braucht den internen Mixer"))
                if am.isOn {
                    if let t = am.next {
                        Text(verbatim: statusText(am, t))
                            .font(Theme.mono(9.z))
                            .foregroundStyle(Theme.bone)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text(am.phase == .starting ? "startet …" : "kein Track")
                            .font(Theme.mono(9.z)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 0)
                    DeckButton(title: "SKIP", color: Theme.gold, width: 44, compact: true) { am.skip() }
                        .disabled(am.phase != .waiting && am.phase != .mixing)
                    DeckButton(title: "STOP", color: Theme.state, width: 44, compact: true) { am.stop(String(localized: "Auto-Mix aus")) }
                } else {
                    Spacer(minLength: 0)
                }
            }
            if am.isOn, !am.queue.isEmpty {
                VStack(alignment: .leading, spacing: 1.z) {
                    ForEach(Array(am.queue.enumerated()), id: \.offset) { i, t in
                        Text(verbatim: "\(i + 1)  \(AutoMixModel.label(t))")
                            .font(Theme.mono(8.z))
                            .foregroundStyle(i == 0 ? Theme.bone : Theme.muted)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `AUTO-MIX · next: Artist – Title · in 24 bars`
    private func statusText(_ am: AutoMixModel, _ t: Track) -> String {
        let label = AutoMixModel.label(t)
        switch am.phase {
        case .mixing: return String(localized: "AUTO-MIX · Übergang · weiter: \(label)")
        case .waiting:
            if let b = am.barsLeft, b > 0 { return String(localized: "AUTO-MIX · weiter: \(label) · in \(b) Takten") }
            return String(localized: "AUTO-MIX · weiter: \(label)")
        default: return "AUTO-MIX · \(label)"
        }
    }
}

/// Eintrag „Auto-Mix starten“ im Baum: zwei oder mehr markierte Einträge (⌘ / ⇧ Klick), die Seiten abwechselnd nach Name
@MainActor
@ViewBuilder func autoMixMenuButton(_ src: BrowserSource, marked: Set<BrowserSource>, mix: MixModel) -> some View {
    let sel = marked.contains(src) ? marked : []
    let internalMode = mix.mixerMode == .internalMixer
    Button("Auto-Mix starten") { mix.autoMix.startFromMarked(sel) }
        .disabled(sel.count < 2 || !internalMode)
        .help(!internalMode ? Text("Auto-Mix braucht den internen Mixer")
                        : sel.count < 2 ? Text("zwei oder mehr Einträge im Baum mit ⌘ / ⇧ markieren")
                        : Text("Auto-Mix mit den markierten Einträgen"))
}
