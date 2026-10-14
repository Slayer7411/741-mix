import SwiftUI
import AppKit
import MixCore

/// Zeichen im Baum (monochrom, IBM Plex Mono): Ordner, Playlist, Smartlist – eigene und aus der Collection gleich
enum OwnGlyph {
    static let folder = "▸"
    static let playlist = "≡"
    static let smartlist = "◇"

    static func of(_ k: PlaylistItem.Kind) -> String {
        switch k {
        case .folder: folder
        case .playlist: playlist
        case .smartlist: smartlist
        }
    }
}

/// Eintrag des eigenen Baums ziehen: auf einen Ordner (hinein), auf einen Eintrag (davor), auf PLAYLISTS (nach oben),
/// auf einen Favoriten-Platz (belegen)
@MainActor
enum TreeDrag {
    static let prefix = "minos741-item:"

    static func provider(_ id: UUID, favorite: BrowserFavorite?) -> NSItemProvider {
        _ = FavoriteDrag.provider(favorite)   // Favoritenleiste liest den Favoriten von dort
        return NSItemProvider(object: (prefix + id.uuidString) as NSString)
    }

    static func item(_ s: String) -> UUID? { s.hasPrefix(prefix) ? UUID(uuidString: String(s.dropFirst(prefix.count))) : nil }
    static func track(_ s: String) -> String? { s.hasPrefix(TrackDrag.prefix) ? String(s.dropFirst(TrackDrag.prefix.count)) : nil }

    /// alle Texte der Provider, auf dem Hauptthread
    @discardableResult
    static func strings(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([String]) -> Void) -> Bool {
        let own = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !own.isEmpty else { return false }
        let box = StringsBox()
        let group = DispatchGroup()
        for p in own {
            group.enter()
            p.loadObject(ofClass: NSString.self) { obj, _ in
                if let s = obj as? String { box.add(s) }
                group.leave()
            }
        }
        group.notify(queue: .main) { MainActor.assumeIsolated { done(box.all) } }
        return true
    }

    private final class StringsBox: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }
}

private struct TreeProviderBox: @unchecked Sendable { let provider: NSItemProvider }

/// Zustand der Dialoge des Baums (Umbenennen, Löschen, Smartlist-Editor), Auf-/Zu der Ordner, Ziel beim Ziehen
@MainActor @Observable
final class PlaylistTreeUI {
    var rootOpen = true
    var collapsed: Set<UUID> = []
    var renaming: PlaylistItem?
    var renameText = ""
    var deleting: PlaylistItem?
    var editing: SmartlistDraft?
    var dropTarget: UUID?
    /// PLAYLISTS selbst als Ziel
    var rootTargeted = false

    func rename(_ i: PlaylistItem) { renameText = i.name; renaming = i }
}

/// Ein Baum „PLAYLISTS“: eigene Ordner / Playlists / Smartlists (änderbar) und darunter die der Collection-Datei
/// (nur lesen, mit ihrer Ordnerstruktur; den eigenen Spiegel `MINOS-741/Playlists` blendet der Baum aus)
struct PlaylistsSection: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(PlaylistTreeUI.self) private var ui
    @Binding var selection: BrowserSource

    var body: some View {
        @Bindable var ui = ui
        DisclosureGroup(isExpanded: $ui.rootOpen) {
            OwnItemsView(items: store.playlists.items, selection: $selection)
            OutlineGroup(store.root.visibleChildren ?? [], children: \.visibleChildren) { node in
                row(icon(node), node.name)
                    .tag(BrowserSource.node(node))
                    .lineLimit(1)
                    .help("aus der Collection-Datei (nur lesen)")
                    .favoriteDrag { BrowserFavorite.source(.node(node), store: store) }
                    .contextMenu {
                        if node.kind != .folder { exportMenu(.node(node)) }
                        OverviewMenuButton { nodeTracks(node) }
                        AnalysisMenuButtons { nodeTracks(node) }
                        CloudMenuButton(label: node.name) { nodeTracks(node) }
                    }
            }
        } label: {
            row("▸", "PLAYLISTS")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(ui.rootTargeted ? Theme.chitinRaised : .clear)
                .contextMenu { PlaylistNewMenu(parent: nil, selection: $selection) }
                .treeDrop(targeted: $ui.rootTargeted) { strings in
                    if let id = strings.compactMap(TreeDrag.item).first {
                        store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: nil) }
                        return true
                    }
                    let keys = strings.compactMap(TreeDrag.track)
                    guard !keys.isEmpty else { return false }
                    let it = store.addOwn(.playlist, into: nil, tracks: keys)
                    selection = .own(OwnRef(it))
                    return true
                }
                .accessibilityIdentifier("tree.playlists")
        }
    }
}

extension PlaylistNode {
    /// Kinder für den Baum: ohne den eigenen Spiegel `MINOS-741/Playlists` (steht schon als eigener Baum darüber)
    var visibleChildren: [PlaylistNode]? {
        guard kind == .folder else { return nil }
        guard name == CollectionWriter.ownFolder else { return children }
        return children.filter { !($0.kind == .folder && $0.name == LibraryStore.ownPlaylistsFolder) }
    }
}

/// Menü „Neu“ an PLAYLISTS und an eigenen Ordnern
struct PlaylistNewMenu: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PlaylistTreeUI.self) private var ui
    let parent: UUID?
    @Binding var selection: BrowserSource

    var body: some View {
        Button("Neue Playlist") {
            let it = store.addOwn(.playlist, into: parent)
            selection = .own(OwnRef(it))
            open(parent)
            ui.rename(it)
        }
        Button("Neue Smartlist …") {
            ui.editing = SmartlistDraft(new: store.playlists.uniqueName(String(localized: "Neue Smartlist"), in: parent), parent: parent)
        }
        Button("Neuer Ordner") {
            let it = store.addOwn(.folder, into: parent)
            open(parent)
            ui.rename(it)
        }
    }

    private func open(_ id: UUID?) {
        ui.rootOpen = true
        if let id { ui.collapsed.remove(id) }
    }
}

/// eigene Einträge einer Ebene (rekursiv)
struct OwnItemsView: View {
    @Environment(PlaylistTreeUI.self) private var ui
    let items: [PlaylistItem]
    @Binding var selection: BrowserSource

    var body: some View {
        ForEach(items) { it in
            if it.kind == .folder {
                DisclosureGroup(isExpanded: Binding(get: { !ui.collapsed.contains(it.id) },
                                                    set: { if $0 { ui.collapsed.remove(it.id) } else { ui.collapsed.insert(it.id) } })) {
                    OwnItemsView(items: it.children, selection: $selection)
                } label: {
                    OwnItemRow(item: it, selection: $selection)
                }
            } else {
                OwnItemRow(item: it, selection: $selection)
            }
        }
    }
}

/// Zeile eines eigenen Eintrags: Auswahl, Rechtsklick, Ziehen, Ablegen (Einträge, Tracks)
struct OwnItemRow: View, SourceMenus {
    @Environment(LibraryStore.self) var store
    @Environment(HistoryStore.self) var history
    @Environment(PlaylistTreeUI.self) private var ui
    let item: PlaylistItem
    @Binding var selection: BrowserSource

    var body: some View {
        let ref = OwnRef(item)
        let src = BrowserSource.own(ref)
        let target = ui.dropTarget == item.id
        row(OwnGlyph.of(item.kind), item.name)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(target ? Theme.chitinRaised : .clear)
            .overlay(alignment: .top) {
                // Eintrag davor einsetzen: Strich über der Zeile (Ordner: Rahmen = hinein)
                if target, item.kind != .folder { Rectangle().fill(Theme.bone.opacity(0.7)).frame(height: 1) }
            }
            .overlay { if target, item.kind == .folder { Rectangle().stroke(Theme.bone.opacity(0.6), lineWidth: 1) } }
            .tag(src)
            .lineLimit(1)
            .help(help)
            .itemProvider {
                let make = { MainActor.assumeIsolated { TreeProviderBox(provider: TreeDrag.provider(item.id, favorite: BrowserFavorite.source(src, store: store))) } }
                return (Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)).provider
            }
            .treeDrop(targeted: Binding(get: { ui.dropTarget == item.id },
                                        set: { ui.dropTarget = $0 ? item.id : (ui.dropTarget == item.id ? nil : ui.dropTarget) })) { drop($0) }
            .contextMenu { menu(src) }
    }

    private var help: String {
        switch item.kind {
        case .folder: String(localized: "Ordner · Einträge hierher ziehen")
        case .playlist: String(localized: "Playlist · Tracks hierher ziehen, Reihenfolge in der Liste per Ziehen, ⌫ entfernt")
        case .smartlist: String(localized: "Smartlist · Rechtsklick → Bearbeiten …")
        }
    }

    private func drop(_ strings: [String]) -> Bool {
        if let id = strings.compactMap(TreeDrag.item).first {
            guard id != item.id else { return false }
            if item.kind == .folder {
                store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: item.id) }
                ui.collapsed.remove(item.id)
            } else if case let .some(parent) = store.playlists.parent(of: item.id) {
                let siblings = parent.flatMap { store.playlists.item($0)?.children } ?? store.playlists.items
                let at = siblings.firstIndex { $0.id == item.id }
                store.editPlaylists(String(localized: "Verschieben")) { $0.move(id, into: parent, at: at) }
            }
            return true
        }
        let keys = strings.compactMap(TreeDrag.track)
        guard !keys.isEmpty, item.kind == .playlist else { return false }
        store.addToPlaylist(keys, item.id)
        return true
    }

    @ViewBuilder private func menu(_ src: BrowserSource) -> some View {
        if item.kind == .folder {
            PlaylistNewMenu(parent: item.id, selection: $selection)
            Divider()
        }
        if item.kind == .smartlist {
            Button("Bearbeiten …") { ui.editing = SmartlistDraft(edit: item) }
        }
        Button("Umbenennen …") { ui.rename(item) }
        if item.kind != .folder {
            Button("Duplizieren") {
                guard case let .some(parent) = store.playlists.parent(of: item.id) else { return }
                var copy = item
                copy.id = UUID()
                copy.name = store.playlists.uniqueName(item.name + " " + String(localized: "Kopie"), in: parent)
                store.editPlaylists(String(localized: "Duplizieren")) { $0.insert(copy, into: parent) }
            }
        }
        if item.kind == .smartlist {
            Button("Als Playlist speichern") {
                let keys = store.ownTracks(item.id).map(\.key)
                guard case let .some(parent) = store.playlists.parent(of: item.id) else { return }
                let it = store.addOwn(.playlist, into: parent, name: item.name, tracks: keys)
                selection = .own(OwnRef(it))
            }
        }
        MoveMenu(item: item)
        Button("Löschen …") { ui.deleting = item }
        Divider()
        if item.kind != .folder { exportMenu(src) }
        OverviewMenuButton { store.ownTracksDeep(item.id) }
        AnalysisMenuButtons { store.ownTracksDeep(item.id) }
        CloudMenuButton(label: item.name) { store.ownTracksDeep(item.id) }
    }
}

/// „Verschieben nach“: PLAYLISTS oben oder ein eigener Ordner (nicht der Eintrag selbst oder darunter)
struct MoveMenu: View {
    @Environment(LibraryStore.self) private var store
    let item: PlaylistItem

    var body: some View {
        let tree = store.playlists
        let current = tree.parent(of: item.id) ?? nil
        Menu("Verschieben nach") {
            Button("PLAYLISTS (oben)") { move(nil) }.disabled(current == nil)
            ForEach(tree.folders.filter { $0.item.id != item.id && !tree.isDescendant($0.item.id, of: item.id) }, id: \.item.id) { f in
                Button(String(repeating: "   ", count: f.depth + 1) + OwnGlyph.folder + " " + f.item.name) { move(f.item.id) }
                    .disabled(current == f.item.id)
            }
        }
    }

    private func move(_ to: UUID?) { store.editPlaylists(String(localized: "Verschieben")) { $0.move(item.id, into: to) } }
}

/// Umbenennen, Löschen mit Rückfrage, Smartlist-Editor – am Baum
struct PlaylistTreeDialogs: ViewModifier {
    @Environment(LibraryStore.self) private var store
    @Bindable var ui: PlaylistTreeUI
    @Binding var selection: BrowserSource

    func body(content: Content) -> some View {
        content
            .alert("Umbenennen", isPresented: Binding(get: { ui.renaming != nil }, set: { if !$0 { ui.renaming = nil } })) {
                TextField("Name", text: $ui.renameText)
                Button("OK") {
                    if let it = ui.renaming {
                        store.editPlaylists(String(localized: "Umbenennen")) { $0.rename(it.id, to: ui.renameText) }
                    }
                    ui.renaming = nil
                }
                Button("Abbrechen", role: .cancel) { ui.renaming = nil }
            }
            .alert(deleteTitle, isPresented: Binding(get: { ui.deleting != nil }, set: { if !$0 { ui.deleting = nil } })) {
                Button("Löschen", role: .destructive) {
                    if let it = ui.deleting { store.editPlaylists(String(localized: "Löschen")) { $0.remove(it.id) } }
                    ui.deleting = nil
                }
                Button("Abbrechen", role: .cancel) { ui.deleting = nil }
            } message: {
                Text(deleteMessage)
            }
            .sheet(item: $ui.editing) { draft in
                SmartlistEditor(draft: draft) { saved in
                    selection = .own(OwnRef(saved))
                    ui.rootOpen = true
                    if let p = draft.parent { ui.collapsed.remove(p) }
                }
            }
    }

    private var deleteTitle: String {
        guard let it = ui.deleting else { return "" }
        return String(localized: "„\(it.name)“ löschen?")
    }

    private var deleteMessage: String {
        guard let it = ui.deleting else { return "" }
        switch it.kind {
        case .folder:
            let n = it.descendantCount
            return n == 0 ? String(localized: "Leerer Ordner. ⌘Z holt ihn zurück.")
                : String(localized: "Mit \(n) Einträgen darin. ⌘Z holt alles zurück.")
        case .playlist: return String(localized: "Playlist mit \(it.tracks.count) Tracks (die Tracks bleiben in der Collection). ⌘Z holt sie zurück.")
        case .smartlist: return String(localized: "Smartlist (nur die Regeln). ⌘Z holt sie zurück.")
        }
    }
}

/// Ablegen auf eine Baum-Zeile über AppKit: eine Ansicht hinter der Zeile, für Text angemeldet (die Liste selbst nimmt
/// in Zeilen nur ihr eigenes Umsortieren an). Klicks gehen durch (`hitTest` = nil)
extension View {
    func treeDrop(targeted: Binding<Bool>, _ perform: @escaping @MainActor ([String]) -> Bool) -> some View {
        background(TreeDropTarget(targeted: targeted, perform: perform))
    }
}

struct TreeDropTarget: NSViewRepresentable {
    @Binding var targeted: Bool
    let perform: @MainActor ([String]) -> Bool

    func makeNSView(context: Context) -> TreeDropView {
        let v = TreeDropView()
        v.registerForDraggedTypes([.string])
        return v
    }

    func updateNSView(_ v: TreeDropView, context: Context) {
        v.perform = perform
        v.onTarget = { on in if targeted != on { targeted = on } }
    }
}

final class TreeDropView: NSView {
    var perform: (@MainActor ([String]) -> Bool)?
    var onTarget: ((Bool) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// eigene Texte (Track- oder Baum-Eintrag) auf dem Pasteboard
    static func strings(_ pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }
            .filter { $0.hasPrefix(TrackDrag.prefix) || $0.hasPrefix(TreeDrag.prefix) }
    }

    private func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let s = Self.strings(info.draggingPasteboard)
        if s.isEmpty { return [] }
        return s.contains { $0.hasPrefix(TreeDrag.prefix) } ? .move : .copy
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let op = operation(info)
        onTarget?(op != [])
        return op
    }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { operation(info) }
    override func draggingExited(_ info: NSDraggingInfo?) { onTarget?(false) }
    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { operation(info) != [] }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        onTarget?(false)
        let s = Self.strings(info.draggingPasteboard)
        return !s.isEmpty && (perform?(s) ?? false)
    }
}
