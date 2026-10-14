import AppKit
import MixCore

/// Track-Tabelle: Tracks ziehen, in eigene Playlists ablegen / dort umsortieren, ⌫ entfernt, Menü „Zur Playlist“
extension TrackTableController {
    func tableView(_ tv: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let r = shownRows
        guard row >= 0, row < r.count else { return nil }
        return (TrackDrag.prefix + r[row].key) as NSString
    }

    func tableView(_ tv: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard model?.ownPlaylistID != nil, !Self.dragKeys(info.draggingPasteboard).isEmpty else { return [] }
        tv.setDropRow(row, dropOperation: .above)
        return (info.draggingSource as? NSTableView) === tv ? .move : .copy
    }

    func tableView(_ tv: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let model, let store, let id = model.ownPlaylistID else { return false }
        let keys = Self.dragKeys(info.draggingPasteboard)
        guard !keys.isEmpty else { return false }
        drop(keys, at: row, into: id, reorder: (info.draggingSource as? NSTableView) === tv, store: store, model: model)
        return true
    }

    /// Ablegen vor Zeile `row` der angezeigten Liste: gleiche Tabelle = Reihenfolge (zeigt danach die Playlist-
    /// Reihenfolge), sonst einfügen
    func drop(_ keys: [String], at row: Int, into id: UUID, reorder: Bool, store: LibraryStore, model: BrowserPaneModel) {
        guard let item = store.playlists.item(id) else { return }
        let rows = shownRows
        let index = row >= 0 && row < rows.count ? item.tracks.firstIndex(of: rows[row].key) ?? item.tracks.count : item.tracks.count
        if reorder {
            store.editPlaylists(String(localized: "Reihenfolge ändern")) { $0.moveTracks(keys, in: id, to: index) }
            if !model.sortOrder.isEmpty { model.sortOrder = [] }
        } else {
            store.addToPlaylist(keys, id, at: index)
        }
    }

    static func dragKeys(_ pb: NSPasteboard) -> [String] {
        (pb.pasteboardItems ?? []).compactMap { $0.string(forType: .string) }.compactMap(TreeDrag.track)
    }

    /// ⌫: Auswahl aus der eigenen Playlist bzw. der Preparation
    func deleteKey() -> Bool {
        guard let model, let store, !model.selection.isEmpty else { return false }
        let ids = model.selection
        if let id = model.ownPlaylistID {
            store.removeFromPlaylist(ids, id)
            return true
        }
        if case .preparation = model.source {
            store.editPreparation(String(localized: "Aus Preparation entfernen")) { $0.removeAll { ids.contains($0) } }
            return true
        }
        return false
    }

    /// Kontextmenü: Zur Playlist hinzufügen (eigene Playlists mit Ordnerpfad, neue Playlist), aus dieser entfernen
    func addPlaylistItems(_ menu: NSMenu, ids: Set<String>, rows: [Track]) {
        guard let store, let model else { return }
        let ordered = rows.map(\.key).filter { ids.contains($0) }
        let keys = ordered.isEmpty ? Array(ids) : ordered
        let sub = NSMenu()
        func walk(_ items: [PlaylistItem], _ depth: Int) {
            for it in items {
                switch it.kind {
                case .folder:
                    let head = NSMenuItem(title: String(repeating: "   ", count: depth) + OwnGlyph.folder + " " + it.name, action: nil, keyEquivalent: "")
                    head.isEnabled = false
                    sub.addItem(head)
                    walk(it.children, depth + 1)
                case .playlist:
                    let id = it.id
                    sub.addItem(ActionItem(String(repeating: "   ", count: depth) + OwnGlyph.playlist + " " + it.name) { store.addToPlaylist(keys, id) })
                case .smartlist: break
                }
            }
        }
        walk(store.playlists.items, 0)
        if !sub.items.isEmpty { sub.addItem(.separator()) }
        sub.addItem(ActionItem(String(localized: "Neue Playlist mit der Auswahl")) {
            let it = store.addOwn(.playlist, into: nil, tracks: keys)
            model.source = .own(OwnRef(it))
        })
        let add = NSMenuItem(title: String(localized: "Zur Playlist hinzufügen"), action: nil, keyEquivalent: "")
        add.submenu = sub
        menu.addItem(add)
        if let id = model.ownPlaylistID {
            let rm = ActionItem(String(localized: "Aus Playlist entfernen")) { store.removeFromPlaylist(ids, id) }
            rm.keyEquivalent = "\u{8}"
            rm.keyEquivalentModifierMask = []
            menu.addItem(rm)
        }
    }
}

extension BrowserPaneModel {
    /// eigene Playlist als Quelle (Ablegen, Reihenfolge, ⌫)
    var ownPlaylistID: UUID? {
        if case let .own(r) = source, r.kind == .playlist { return r.id }
        return nil
    }
}
