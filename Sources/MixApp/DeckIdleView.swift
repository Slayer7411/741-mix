import SwiftUI
import AppKit
import CoreImage
import MixEngine

/// Wellenform-Fläche eines leeren Decks: nach einem Ladefehler 5 s ein Totenkopf mit Grund,
/// danach (und immer ohne Track) der Lobster. Mit Track: nichts.
struct DeckIdleView: View {
    enum Mode { case skull, lobster }

    @Environment(MixModel.self) private var mix
    let d: Int
    /// Selbsttest-Bild: Darstellung erzwingen
    var forced: Mode?
    var forcedReason: String?
    /// neu zeichnen, wenn die Totenkopf-Zeit um ist
    @State private var tick = 0

    static let skullSeconds: Double = 5

    var body: some View {
        let deck = mix.deck(d)
        let failedAt = StatusCenter.shared.loadFailed[d]
        let skull = tick >= 0 && deck.error != nil && failedAt.map { Date().timeIntervalSince($0) < Self.skullSeconds } == true
        let mode: Mode? = forced ?? (deck.track != nil || deck.loading ? nil : (skull ? .skull : .lobster))
        ZStack {
            switch mode {
            case .skull: SkullArt(reason: forcedReason ?? deck.error ?? "")
            case .lobster: LobsterMark()
            case nil: EmptyView()
            }
        }
        .allowsHitTesting(false)
        .task(id: failedAt) {
            guard let f = failedAt else { return }
            let left = Self.skullSeconds - Date().timeIntervalSince(f)
            if left > 0 { try? await Task.sleep(for: .seconds(left)) }
            if !Task.isCancelled { tick += 1 }
        }
    }
}

/// Totenkopf in Zeichen, auf die Fläche skaliert; Augen in 741-Rot, Grund darunter
struct SkullArt: View {
    let reason: String

    static let lines = [
        "        _.-~~~~~~~~~~~-._        ",
        "     .-'                 '-.     ",
        "   .'                       '.   ",
        "  /                           \\  ",
        " ;                             ; ",
        " |   .-~~~~-.       .-~~~~-.   | ",
        " |  /        \\     /        \\  | ",
        " |  |   @    |     |    @   |  | ",
        " ;  \\        /     \\        /  ; ",
        "  \\  '-.__.-'  /^\\  '-.__.-'  /  ",
        "   '.         /___\\         .'   ",
        "     |   .-.-.-.-.-.-.-.   |     ",
        "     |   | | | | | | | |   |     ",
        "     |   '-'-'-'-'-'-'-'   |     ",
        "      '-.______.-.______.-'      ",
    ]

    var body: some View {
        GeometryReader { geo in
            let cols = CGFloat(Self.lines.map(\.count).max() ?? 1), rows = CGFloat(Self.lines.count) + 2.2
            // Plex Mono: Zeichenbreite 0,6 em, Zeilenhöhe ~1,0 em bei lineSpacing 0
            let size = max(4, min(geo.size.width * 0.92 / (cols * 0.6), geo.size.height * 0.94 / (rows * 1.02)))
            VStack(spacing: 0) {
                ForEach(Self.lines.indices, id: \.self) { i in
                    Text(Self.attributed(Self.lines[i]))
                        .font(.custom("IBM Plex Mono", size: size).weight(.medium))
                        .fixedSize()
                        .frame(height: size * 1.02)
                }
                Text(verbatim: reason.uppercased())
                    .font(Theme.mono(max(9, size * 0.9), .semibold))
                    .foregroundStyle(Theme.state)
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.top, size * 0.6)
                    .frame(maxWidth: geo.size.width * 0.9)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.wave)
    }

    /// Augen rot, Rest Knochenweiß
    static func attributed(_ line: String) -> AttributedString {
        var a = AttributedString(line)
        a.foregroundColor = Theme.bone
        var i = a.startIndex
        while i < a.endIndex {
            let next = a.index(afterCharacter: i)
            if a.characters[i] == "@" { a[i..<next].foregroundColor = Theme.state }
            i = next
        }
        return a
    }
}

/// Lobster (Christians lobster2) als Silhouette in Knochenweiß, gedämpft, mittig
struct LobsterMark: View {
    var body: some View {
        GeometryReader { geo in
            if let img = Self.mask {
                Image(decorative: img, scale: 1)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Theme.bone.opacity(0.22))
                    .padding(.vertical, geo.size.height * 0.08)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Theme.wave)
    }

    /// Schwarz-auf-Weiß-Vorlage -> Maske (Silhouette deckend, Rest durchsichtig), einmal berechnet
    @MainActor static let mask: CGImage? = {
        guard let url = AppResources.url("Lobster", "png"), let src = CIImage(contentsOf: url) else { return nil }
        let white = CIImage(color: .white).cropped(to: src.extent)
        let flat = src.composited(over: white)
        guard let inv = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: flat])?.outputImage,
              let alpha = CIFilter(name: "CIMaskToAlpha", parameters: [kCIInputImageKey: inv])?.outputImage else { return nil }
        return CIContext().createCGImage(alpha, from: src.extent)
    }()
}
