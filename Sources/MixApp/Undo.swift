import AppKit
import Observation
import MixCore
import MixEngine

/// ein Schritt zum Rückgängigmachen
struct UndoEntry {
    var label: String
    var undo: @MainActor () -> Void
    var redo: (@MainActor () -> Void)?
    /// Deck des Eintrags (Trackwechsel wirft ihn weg), nil = Browser
    var deck: Int?
    /// gleiche Kennung kurz hintereinander = ein Eintrag (Fader ziehen, Grid nudgen)
    var coalesce: String?
    /// zuletzt geändert (Systemzeit, s)
    var time = 0.0
    /// Vorher-Stand; ein verschmolzener Eintrag behält den ersten
    var before: Any?
}

/// Rückgängig-Stapel der App (flüchtig, höchstens `limit` Einträge). Während Rückgängig/Wiederherstellen läuft,
/// wird nichts aufgezeichnet
@MainActor @Observable
final class UndoStack {
    static let shared = UndoStack()
    static let limit = 100

    /// Bezeichnung des nächsten Schritts (Menü), nil = leer
    private(set) var undoLabel: String?
    private(set) var redoLabel: String?
    @ObservationIgnored private(set) var done: [UndoEntry] = []
    @ObservationIgnored private(set) var undone: [UndoEntry] = []
    @ObservationIgnored private(set) var replaying = false

    var canUndo: Bool { !done.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    nonisolated static var now: Double { ProcessInfo.processInfo.systemUptime }

    func push(_ e: UndoEntry) {
        guard !replaying else { return }
        done.append(e)
        if done.count > Self.limit { done.removeFirst(done.count - Self.limit) }
        undone.removeAll()
        refresh()
    }

    /// Vorher/Nachher sichern; `apply(vorher, nachher, rückgängig)` stellt den einen oder anderen Stand her.
    /// Gleiche `coalesce`-Kennung innerhalb von `window` s ersetzt den obersten Eintrag (Vorher bleibt der erste)
    func record<S>(_ label: String, deck: Int? = nil, coalesce: String? = nil, window: Double = 1, now: Double = UndoStack.now,
                   before: S, after: S, apply: @escaping @MainActor (_ before: S, _ after: S, _ undo: Bool) -> Void) {
        guard !replaying else { return }
        var first = before
        if let c = coalesce, undone.isEmpty, let top = done.last, top.coalesce == c, now - top.time < window, let b = top.before as? S {
            first = b
            done.removeLast()
        }
        let b = first
        push(UndoEntry(label: label, undo: { apply(b, after, true) }, redo: { apply(b, after, false) },
                       deck: deck, coalesce: coalesce, time: now, before: b))
    }

    /// obersten Schritt zurücknehmen; Bezeichnung oder nil (leer)
    @discardableResult
    func undo() -> String? {
        guard let e = done.popLast() else { return nil }
        replay(e.undo)
        if e.redo != nil { undone.append(e) } else { undone.removeAll() }
        seal()
        return e.label
    }

    @discardableResult
    func redo() -> String? {
        guard let e = undone.popLast(), let r = e.redo else { return nil }
        replay(r)
        done.append(e)
        seal()
        return e.label
    }

    /// Menü / Taste: Schritt ausführen, Hinweis in der Statusleiste; leer = Warnton
    func perform(redo: Bool) {
        guard let l = redo ? self.redo() : undo() else { NSSound.beep(); return }
        StatusCenter.post(.info, redo ? String(localized: "Wiederhergestellt: \(l)") : String(localized: "Rückgängig: \(l)"), key: "undo")
    }

    /// Trackwechsel im Deck: seine Schritte passen nicht mehr zum neuen Track
    func clear(deck d: Int) {
        guard done.contains(where: { $0.deck == d }) || undone.contains(where: { $0.deck == d }) else { return }
        done.removeAll { $0.deck == d }
        undone.removeAll { $0.deck == d }
        refresh()
    }

    func clearAll() {
        done.removeAll()
        undone.removeAll()
        refresh()
    }

    private func replay(_ f: @MainActor () -> Void) {
        replaying = true
        f()
        replaying = false
    }

    /// nach Rückgängig/Wiederherstellen verschmilzt der nächste Schritt nicht mit dem obersten
    private func seal() {
        if !done.isEmpty { done[done.count - 1].coalesce = nil }
        refresh()
    }

    private func refresh() {
        let u = done.last?.label, r = undone.last?.label
        if u != undoLabel { undoLabel = u }
        if r != redoLabel { redoLabel = r }
    }
}

/// Deck-Aktionen aufzeichnen: Stand vor und nach der Aktion sichern (nur die gewählten Teile), Rückgängig schreibt
/// den Vorher-Stand zurück. Kein Eintrag, wenn sich nichts geändert hat oder kein Track geladen ist
@MainActor
final class DeckUndoRecorder {
    let core: MixController
    let stack: UndoStack
    /// nach Rückgängig/Wiederherstellen (Spiegel holen)
    var changed: @MainActor () -> Void = {}

    init(core: MixController, stack: UndoStack? = nil) {
        self.core = core
        self.stack = stack ?? .shared
    }

    static func label(_ text: String, deck d: Int) -> String { "\(text) · Deck \(deckLetters[d])" }

    func edit(_ d: Int, _ text: String, _ parts: DeckEdit.Parts, coalesce: String? = nil, window: Double = 1, _ f: () -> Void) {
        guard !stack.replaying else { f(); return }
        let before = core.deckEdit(d)
        f()
        let after = core.deckEdit(d)
        guard before.trackKey != nil, !before.same(as: after, in: parts) else { return }
        stack.record(Self.label(text, deck: d), deck: d, coalesce: coalesce.map { "\($0).\(d)" }, window: window,
                     before: before, after: after) { [core, weak self] b, a, undo in
            // Position als Versatz (ein spielendes Deck läuft seit der Aktion weiter); ohne Sprung kein Seek
            let delta = (a.position - b.position) * (undo ? -1 : 1)
            let target = parts.contains(.position) && abs(delta) >= DeckEdit.positionTolerance ? core.position(d) + delta : nil
            core.restoreDeckEdit(d, undo ? b : a, parts, changedFrom: undo ? a : b, position: target)
            self?.changed()
        }
    }
}
