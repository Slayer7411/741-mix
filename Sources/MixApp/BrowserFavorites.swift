import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MixCore

/// Favoriten eines Browser-Bereichs: 6 Plätze über dem Baum, je Platz eine Quelle oder ein Filter.
extension BrowserFavorite {
    /// Ziel eines Favoriten in der geladenen Collection
    enum Target {
        case source(BrowserSource)
        case filter
        case missing
    }

    /// Favorit für eine Quelle; nil = nicht ablegbar (Archive)
    @MainActor static func source(_ s: BrowserSource, store: LibraryStore) -> BrowserFavorite? {
        switch s {
        case .collection: BrowserFavorite(.collection, name: s.title)
        case .preparation: BrowserFavorite(.preparation, name: s.title)
        case .running: BrowserFavorite(.running, name: s.title)
        case .historyLive: BrowserFavorite(.history, name: s.title)
        case let .custom(c): BrowserFavorite(.smartlist, name: c.name, id: c.id.uuidString, path: [c.name])
        case let .node(n): BrowserFavorite.node(n, in: store.root)
        case let .folder(p): BrowserFavorite(.folder, name: s.title, path: [p])
        case .history, .prepArchive: nil
        }
    }

    /// Ziel suchen: Knoten über UUID / Pfad, eigene Smartlist über ID / Name, Musik-Ordner über den Pfad
    @MainActor func target(store: LibraryStore) -> Target {
        switch kind {
        case .collection: return .source(.collection)
        case .preparation: return .source(.preparation)
        case .running: return .source(.running)
        case .history: return .source(.historyLive)
        case .filter: return .filter
        case .smartlist:
            let l = store.customSmartlists
            return (l.first { $0.id.uuidString == id } ?? l.first { $0.name == path?.first }).map { .source(.custom($0)) } ?? .missing
        case .node:
            return resolveNode(in: store.root).map { .source(.node($0)) } ?? .missing
        case .folder:
            // ohne Dateizugriff auf dem Hauptthread: fehlt nur, wenn die Liste des Elternordners ihn nicht mehr hat
            guard let p = path?.first else { return .missing }
            if store.folders.roots.contains(p) { return .source(.folder(p)) }
            let subs = store.folders.subfolders((p as NSString).deletingLastPathComponent)
            return subs.map { $0.contains(p) } == false ? .missing : .source(.folder(p))
        case nil: return .missing
        }
    }

    /// Zeichen wie im Baum
    var glyph: String {
        switch kind {
        case .collection: "≣"
        case .running: "▶"
        case .preparation: "▤"
        case .history: "◷"
        case .smartlist: "◆"
        case .folder: "▱"
        case .filter: "▽"
        case .node: nodeKind == .folder ? "▸" : nodeKind == .smartlist ? "◇" : "▤"
        case nil: "·"
        }
    }
}

extension BrowserSource {
    /// gleiche Quelle (eigene Smartlist: gleiche ID, auch nach dem Bearbeiten)
    func same(_ o: BrowserSource) -> Bool {
        if case let .custom(a) = self, case let .custom(b) = o { return a.id == b.id }
        return self == o
    }
}

extension ShortcutID {
    static let favorites: [ShortcutID] = [.favorite1, .favorite2, .favorite3, .favorite4, .favorite5, .favorite6]
}

extension BrowserPaneModel {
    var filterFavorite: BrowserFavorite? { .filter(tags: tags, roles: Set(roles.map(\.rawValue)), search: search) }

    func isActive(_ f: BrowserFavorite, _ t: BrowserFavorite.Target) -> Bool {
        switch t {
        case let .source(s): source.same(s)
        case .filter: f.matchesFilter(tags: tags, roles: Set(roles.map(\.rawValue)), search: search)
        case .missing: false
        }
    }

    /// Platz `i` anwenden: Quelle wechseln bzw. Filter setzen (aktiver Filter: lösen)
    func applyFavorite(_ i: Int, store: LibraryStore) {
        guard favorites.indices.contains(i), let f = favorites[i] else { return }
        let t = f.target(store: store)
        switch t {
        case let .source(s):
            if !source.same(s) { source = s }
        case .filter:
            if isActive(f, t) {
                tags = []; roles = []; search = ""
            } else {
                tags = Set(f.tags ?? [])
                roles = Set((f.roles ?? []).compactMap(RoleFilter.init(rawValue:)))
                search = f.search ?? ""
            }
        case .missing: break
        }
    }
}

/// Ziehen aus dem Baum auf einen Favoriten-Platz: der Baum legt den Favoriten hier ab, auf dem Pasteboard nur der Name
@MainActor
enum FavoriteDrag {
    private static var current: (fav: BrowserFavorite, at: Date)?

    static func provider(_ f: BrowserFavorite?) -> NSItemProvider? {
        guard let f else { return nil }
        current = (f, Date())
        return NSItemProvider(object: f.name as NSString)
    }

    /// abgelegter Favorit (nur aus einem Zug der letzten Minute)
    static func take() -> BrowserFavorite? {
        defer { current = nil }
        guard let c = current, Date().timeIntervalSince(c.at) < 60 else { return nil }
        return c.fav
    }

    static var active: Bool { current.map { Date().timeIntervalSince($0.at) < 60 } ?? false }
}

extension View {
    /// Baum-Eintrag auf einen Favoriten-Platz ziehbar (Ziehen über die Liste selbst, Klick wählt weiter aus)
    func favoriteDrag(_ fav: @escaping @MainActor () -> BrowserFavorite?) -> some View {
        itemProvider {
            let make = { MainActor.assumeIsolated { ProviderBox(provider: FavoriteDrag.provider(fav())) } }
            return (Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)).provider
        }
    }
}

private struct ProviderBox: @unchecked Sendable { let provider: NSItemProvider? }

/// Favoritenleiste: 6 gleich breite Plätze. Klick = Quelle / Filter, Rechtsklick = belegen, umbenennen, leeren,
/// Eintrag aus dem Baum hierher ziehen = belegen.
struct FavoritesBar: View {
    @Environment(LibraryStore.self) private var store
    @Environment(BrowserState.self) private var browser
    @Bindable var model: BrowserPaneModel
    var keys: ShortcutMap?
    @State private var renaming: Int?
    @State private var renameText = ""
    @State private var dropTarget: Int?

    static let height: CGFloat = 20

    var body: some View {
        // vor dem ersten Laden fehlt nichts, die Collection ist nur noch nicht da
        let loaded = store.sourceURL != nil
        HStack(spacing: 0) {
            ForEach(0..<BrowserFavorite.slots, id: \.self) { i in
                if i > 0 { Rectangle().fill(Theme.hairline).frame(width: 1) }
                slot(i, loaded: loaded)
            }
        }
        .frame(height: Self.height)
        .background(Theme.void)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func slot(_ i: Int, loaded: Bool) -> some View {
        let fav = model.favorites.indices.contains(i) ? model.favorites[i] : nil
        let target = fav?.target(store: store)
        let missing = loaded && { if case .missing = target { return true } else { return false } }()
        let active = fav.flatMap { f in target.map { model.isActive(f, $0) } } ?? false
        return Button {
            browser.activePaneID = model.id
            model.applyFavorite(i, store: store)
        } label: {
            HStack(spacing: 4) {
                if let fav {
                    Text(verbatim: fav.glyph).font(Theme.mono(9)).foregroundStyle(active ? Theme.bone : Theme.muted)
                    Text(verbatim: fav.name.uppercased())
                        .font(Theme.label(10, .bold))
                        .strikethrough(missing, color: Theme.muted)
                        .foregroundStyle(active ? Theme.bone : missing ? Theme.muted : Theme.bone.opacity(0.8))
                        .lineLimit(1).truncationMode(.tail)
                } else {
                    Text(verbatim: "—").font(Theme.mono(10)).foregroundStyle(Theme.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(active ? Theme.state.opacity(0.85) : dropTarget == i ? Theme.chitinRaised : .clear)
            .overlay { if dropTarget == i { Rectangle().stroke(Theme.bone.opacity(0.6), lineWidth: 1) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(i, fav, missing: missing))
        .contextMenu { menu(i, fav) }
        .onDrop(of: [.text], isTargeted: Binding(get: { dropTarget == i },
                                                 set: { dropTarget = $0 && FavoriteDrag.active ? i : (dropTarget == i ? nil : dropTarget) })) { _ in
            guard let f = FavoriteDrag.take() else { return false }
            model.favorites[i] = f
            return true
        }
        .popover(isPresented: Binding(get: { renaming == i }, set: { if !$0, renaming == i { renaming = nil } }), arrowEdge: .bottom) {
            renameField(i)
        }
    }

    @ViewBuilder private func menu(_ i: Int, _ fav: BrowserFavorite?) -> some View {
        let src = BrowserFavorite.source(model.source, store: store)
        Button("Aktuelle Quelle hier ablegen") { model.favorites[i] = src }
            .disabled(src == nil)
        Button("Aktuellen Filter hier ablegen") { model.favorites[i] = model.filterFavorite }
            .disabled(model.filterFavorite == nil)
        if fav != nil {
            Divider()
            Button("Umbenennen …") { renameText = fav?.name ?? ""; renaming = i }
            Button("Leeren") { model.favorites[i] = nil }
        }
    }

    private func renameField(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAVORIT UMBENENNEN").font(Theme.label(11, .bold))
            TextField("NAME", text: $renameText)
                .textFieldStyle(.plain).font(Theme.mono(11))
                .padding(4).background(Theme.void).overlay(Rectangle().stroke(Theme.hairline, lineWidth: 1))
                .onSubmit { rename(i) }
            HStack {
                Spacer()
                DeckButton(title: "ABBRECHEN") { renaming = nil }
                DeckButton(title: "OK", active: true) { rename(i) }
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(Theme.chitin)
    }

    /// leerer Name -> wieder der Name der Quelle bzw. des Filters
    private func rename(_ i: Int) {
        defer { renaming = nil }
        guard var f = model.favorites[i] else { return }
        let n = renameText.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty {
            f.name = n
        } else if case let .source(s) = f.target(store: store) {
            f.name = s.title
        } else if f.isFilter, let d = BrowserFavorite.filter(tags: Set(f.tags ?? []), roles: Set(f.roles ?? []), search: f.search ?? "") {
            f.name = d.name
        }
        model.favorites[i] = f
    }

    private func help(_ i: Int, _ fav: BrowserFavorite?, missing: Bool) -> String {
        let key = keys?.combo(ShortcutID.favorites[i]).map { " · \($0.symbols)" } ?? ""
        guard let fav else {
            return String(localized: "Favorit \(i + 1) · leer · Rechtsklick: Quelle oder Filter ablegen, oder Eintrag aus dem Baum hierher ziehen") + key
        }
        if missing { return String(localized: "Ziel nicht gefunden: \(fav.name) · Rechtsklick: neu belegen") }
        if fav.isFilter { return String(localized: "Filter: \(fav.name) · Klick = anwenden, nochmal = lösen") + key }
        return String(localized: "Favorit \(i + 1): \(fav.name)") + key
    }
}
