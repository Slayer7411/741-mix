import Foundation
import Testing
@testable import MixCore

@Test func keyComboText() {
    let c = KeyCombo("P", [.command, .option])
    #expect(c.key == "p")
    #expect(c.id == "opt+cmd+p")
    #expect(c.symbols == "⌥⌘P")
    #expect(KeyCombo(id: "opt+cmd+p") == c)
    #expect(KeyCombo(id: "cmd+space")?.symbols == "⌘SPACE")
    #expect(KeyCombo(id: "ctrl+cmd+1")?.symbols == "⌃⌘1")
    #expect(KeyCombo(id: "opt+cmd+left")?.symbols == "⌥⌘←")
    #expect(KeyCombo(id: "shift+f5")?.symbols == "⇧F5")
    #expect(KeyCombo(id: "cmd++")?.key == "+")
    #expect(KeyCombo(id: "space")?.isPlain == true)
    #expect(KeyCombo(id: "shift+x")?.isPlain == true)
    #expect(KeyCombo(id: "cmd+x")?.isPlain == false)
    #expect(KeyCombo(id: "cmd+banana") == nil)
    #expect(KeyCombo(id: "") == nil)
    // Modifier-Reihenfolge egal beim Lesen, beim Schreiben immer ⌃⌥⇧⌘
    #expect(KeyCombo(id: "cmd+ctrl+shift+opt+k")?.id == "ctrl+opt+shift+cmd+k")
}

@Test func keyComboCoding() throws {
    let map = ["a": KeyCombo("y"), "b": KeyCombo("right", [.option, .command])]
    let data = try JSONEncoder().encode(map)
    #expect(String(decoding: data, as: UTF8.self).contains("\"opt+cmd+right\""))
    #expect(try JSONDecoder().decode([String: KeyCombo].self, from: data) == map)
    #expect((try? JSONDecoder().decode([KeyCombo].self, from: Data(#"["cmd+nope"]"#.utf8))) == nil)
}

@Test func shortcutDefaultsAndConflicts() {
    // IDs eindeutig, Standardbelegung ohne Doppelte
    #expect(Set(ShortcutID.allCases.map(\.rawValue)).count == ShortcutID.allCases.count)
    var m = ShortcutMap()
    #expect(m.conflicts.isEmpty)
    #expect(m.combo(.resetPlayed)?.symbols == "⌥⌘P")
    #expect(m.combo(.play)?.symbols == "⌘SPACE")
    #expect(m.combo(.bigBrowserKey)?.symbols == "SPACE")
    #expect(m.action(for: KeyCombo("y")) == .sync)
    #expect(m.combo(.favorite1)?.symbols == "⌃⌥1" && m.combo(.favorite6)?.symbols == "⌃⌥6")
    #expect(ShortcutID.favorite4.group == .browser && ShortcutID.favorite4.index == 3)
    // eigener Wert, Konflikt, frei, zurück auf Standard
    m.set(.sync, KeyCombo("l"))
    #expect(m.overrides == ["deck.sync": "cmd+l"])
    #expect(m.conflicts[KeyCombo("l")] == [.loop, .sync])
    #expect(m.conflicting(.loop) == [.sync])
    #expect(m.action(for: KeyCombo("l")) == .sync)   // erste in Listenreihenfolge
    m.set(.loop, nil)
    #expect(m.combo(.loop) == nil)
    #expect(m.overrides["deck.loop"] == "")
    #expect(m.conflicts.isEmpty)
    m.set(.loop, ShortcutID.loop.defaultCombo)
    #expect(m.overrides["deck.loop"] == nil)
    // kaputter gespeicherter Wert -> Standard
    #expect(ShortcutMap(overrides: ["deck.sync": "???"]).combo(.sync) == KeyCombo("y"))
    #expect(KeyCombo.conflicts(["a": KeyCombo("x"), "b": KeyCombo("x"), "c": KeyCombo("z")]) == [KeyCombo("x"): ["a", "b"]])
}
