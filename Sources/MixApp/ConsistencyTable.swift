import SwiftUI
import AppKit

/// Zeile der Prüf-Tabelle. `id` bleibt über Aktualisierungen gleich (Auswahl), `tint` färbt die erste Spalte.
struct CheckRow: Equatable {
    var id: Int
    var cells: [String]
    var tint: NSColor
}

/// Spalte der Prüf-Tabelle. `muted`: Text gedämpft (Befund, Hinweise)
struct CheckColumn: Equatable {
    var title: String
    var width: CGFloat
    var minWidth: CGFloat = 40
    var muted = false
}

/// Tabelle für die Prüf-Fenster (AppKit, wie die Track-Tabelle): mehrere Zeilen wählen, Doppelklick auf einen
/// Spaltentrenner passt die Spalte an den längsten Text an (`TrackHeaderView`, wie dort), Rechtsklick-Menü je Auswahl.
struct CheckTable: NSViewRepresentable {
    var rows: [CheckRow]
    var columns: [CheckColumn]
    /// gewählte Zeilen-Kennungen (von außen gesetzt)
    var selected: Set<Int>
    var onSelect: (Set<Int>) -> Void
    var onActivate: (Set<Int>) -> Void
    var menu: (Set<Int>) -> NSMenu?

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CheckTable
        var rows: [CheckRow] = []
        var columns: [CheckColumn] = []
        /// programmatische Auswahl: keine Rückmeldung
        var syncing = false
        weak var table: CheckTableView?
        private static let font = NSFont(name: "IBM Plex Mono", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)

        init(_ parent: CheckTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func selectedIDs() -> Set<Int> {
            guard let tv = table else { return [] }
            return Set(tv.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0].id : nil })
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let id = tableColumn?.identifier, let ci = Int(id.rawValue.dropFirst()), ci < columns.count, row < rows.count else { return nil }
            let r = rows[row]
            let cell: NSTextField
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
                cell = reused
            } else {
                cell = NSTextField(labelWithString: "")
                cell.identifier = id
                cell.font = Self.font
                cell.lineBreakMode = .byTruncatingMiddle
                cell.cell?.truncatesLastVisibleLine = true
            }
            let text = ci < r.cells.count ? r.cells[ci] : ""
            cell.stringValue = text
            cell.toolTip = text
            cell.textColor = ci == 0 ? r.tint : (columns[ci].muted ? NSColor(Theme.muted) : NSColor(Theme.bone))
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncing else { return }
            parent.onSelect(selectedIDs())
        }

        @objc func activated(_ sender: Any?) {
            parent.onActivate(selectedIDs())
        }

        /// Spalte auf den längsten Text (Kandidaten nach Zeichenzahl, Plex Mono ist dicktengleich): die längsten 8
        /// genau gemessen, Titel der Kopfzeile muss auch passen
        func fit(_ ci: Int) {
            guard let tv = table, ci >= 0, ci < tv.tableColumns.count, ci < columns.count else { return }
            var best: [(Int, String)] = []
            for r in rows where ci < r.cells.count {
                let s = r.cells[ci]
                guard !s.isEmpty else { continue }
                let n = s.utf16.count
                if best.count < 8 { best.append((n, s)); best.sort { $0.0 > $1.0 } }
                else if n > best[best.count - 1].0 { best[best.count - 1] = (n, s); best.sort { $0.0 > $1.0 } }
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
            var w: CGFloat = 0
            for (_, s) in best { w = max(w, NSAttributedString(string: s, attributes: attrs).size().width) }
            let c = tv.tableColumns[ci]
            let header = NSAttributedString(string: columns[ci].title, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold)]).size().width + 14
            c.width = min(c.maxWidth, max(w + 8, header, c.minWidth).rounded(.up))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = NSColor(Theme.chitin)
        let tv = CheckTableView()
        tv.coordinator = context.coordinator
        tv.headerView = TrackHeaderView(frame: .zero)
        tv.allowsMultipleSelection = true
        tv.allowsEmptySelection = true
        tv.allowsColumnReordering = false
        tv.usesAlternatingRowBackgroundColors = false
        tv.rowHeight = 17
        tv.intercellSpacing = NSSize(width: 8, height: 0)
        tv.gridStyleMask = []
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.backgroundColor = NSColor(Theme.chitin)
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.activated(_:))
        (tv.headerView as? TrackHeaderView)?.onFitColumn = { [weak c = context.coordinator] i in c?.fit(i) }
        sv.documentView = tv
        context.coordinator.table = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = sv.documentView as? CheckTableView else { return }
        tv.menuProvider = menu
        if c.columns != columns {
            // Spalten neu aufbauen (Breiten der Vorgabe; danach passt der Benutzer sie an)
            c.columns = columns
            for col in tv.tableColumns { tv.removeTableColumn(col) }
            for (i, col) in columns.enumerated() {
                let tc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                tc.title = col.title
                tc.headerCell.font = NSFont.systemFont(ofSize: 10, weight: .bold)
                tc.headerCell.textColor = NSColor(Theme.muted)
                tc.minWidth = col.minWidth
                tc.width = col.width
                tc.resizingMask = .userResizingMask
                tv.addTableColumn(tc)
            }
        }
        if c.rows != rows {
            c.rows = rows
            tv.reloadData()
        }
        // Auswahl nachziehen, ohne Rückmeldung
        if c.selectedIDs() != selected {
            c.syncing = true
            let index = IndexSet(rows.indices.filter { selected.contains(rows[$0].id) })
            tv.selectRowIndexes(index, byExtendingSelection: false)
            c.syncing = false
        }
    }
}

/// Tabelle mit Rechtsklick-Menü für die Auswahl (Zeile unter dem Mauszeiger wird vorher gewählt)
final class CheckTableView: NSTableView {
    weak var coordinator: CheckTable.Coordinator?
    var menuProvider: ((Set<Int>) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return menuProvider?(coordinator?.selectedIDs() ?? [])
    }
}
