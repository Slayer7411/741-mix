import SwiftUI
import MixCore
import MixEngine

/// Cover eines Tracks: aus dem Speicher-Cache sofort, sonst im Hintergrund geladen (nie auf dem Main-Thread).
/// Neu geladen wird nur, wenn sich der Pfad ändert; verschwindet die Ansicht, wird das Laden abgebrochen.
struct CoverImage<Placeholder: View>: View {
    let path: String?
    let size: ArtworkCache.Size
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: (path: String, image: CGImage?)?

    var body: some View {
        let img: CGImage? = path.flatMap { p in loaded?.path == p ? loaded?.image : (ArtworkCache.shared.cached(p, size) ?? nil) }
        ZStack {
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            guard let path, ArtworkCache.shared.cached(path, size) == nil else { return }
            let i = await ArtworkCache.shared.image(path, size)
            if !Task.isCancelled { loaded = (path, i) }
        }
    }
}

/// Deck-Kopf: quadratisches Cover links vom Titel, Platzhalter ◆ auf Chitin. Hängt nur am Pfad des Tracks.
struct CoverTile: View {
    @Environment(MixModel.self) private var mix
    let d: Int

    var body: some View {
        if mix.prefs.ui.showDeckCover {
            DeckCover(path: mix.deck(d).track?.path).equatable()
        }
    }

    private struct DeckCover: View, Equatable {
        let path: String?
        var body: some View {
            CoverImage(path: path, size: .large) {
                Text("◆").font(Theme.mono(11.z)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.chitin)
            }
            .frame(width: 32.z, height: 32.z)
            .clipped()
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
        }
    }
}

/// Browser-Spalte „Cover“: kleines Vorschaubild, lädt nur für sichtbare Zeilen
struct CoverThumb: View {
    let path: String
    @State private var loaded: (path: String, image: CGImage?)?

    // schlank gehalten (je sichtbare Zeile eine Instanz): Bild oder nichts, Bilder sind schon quadratisch
    var body: some View {
        let img = loaded?.path == path ? loaded?.image : (ArtworkCache.shared.cached(path, .small) ?? nil)
        Group {
            if let img { Image(decorative: img, scale: 1).resizable().interpolation(.high) } else { Color.clear }
        }
        .frame(width: 16.z, height: 16.z)   // passt in die normale Zeilenhöhe (18 pt machte jede Zeile 2 pt höher)
        .task(id: path) {
            guard ArtworkCache.shared.cached(path, .small) == nil else { return }
            let i = await ArtworkCache.shared.image(path, .small)
            if !Task.isCancelled { loaded = (path, i) }
        }
    }
}

/// Vorschau unter dem Baum: Cover des gewählten Tracks im Bereich
struct CoverPreview: View {
    @Environment(LibraryStore.self) private var store
    let model: BrowserPaneModel

    var body: some View {
        let path = model.selection.first.flatMap { store.track($0) }?.path
        VStack(spacing: 0) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
            CoverImage(path: path, size: .large) {
                // „kein Cover“ erst, wenn das Laden fertig ist (sonst blitzt es bei jedem Wechsel auf)
                let none = path.flatMap { ArtworkCache.shared.cached($0, .large) }.map { $0 == nil } ?? false
                Text(none ? String(localized: "◆ KEIN COVER") : "◆").font(Theme.mono(10.z)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.void)
            }
            .frame(width: 140.z, height: 140.z)
            .clipped()
            .overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
            .padding(8.z)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.chitin)
    }
}
