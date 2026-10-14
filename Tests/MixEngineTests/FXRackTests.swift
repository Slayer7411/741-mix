import Foundation
import Testing
@testable import MixEngine

// Insert-Slots: Modell, Übernahme alter Sitzungen (GRP/SNGL/PLUGIN-Kette) und gemerkter Belegungen.

private func decode(_ json: String) throws -> FXUnitState { try JSONDecoder().decode(FXUnitState.self, from: Data(json.utf8)) }

/// GRP → Vorlage Gruppe: Stärke je Slot (Filter: Cutoff), Delay-Zeit und Raumgröße in die Slots, Hall ohne Send
@Test func oldGroupBecomesThreeSlots() throws {
    let fx = try decode(#"{"single":false,"slots":[{"on":true,"amount":0.3},{"on":false,"amount":0.7},{"on":true,"amount":0.6}],"slotTypes":[0,1,2],"delayIndex":2,"reverbSize":0.8,"dryWet":0.5,"opts":{"GATER.rate":0.25}}"#)
    #expect(fx.slots.map(\.id) == ["FILTER", "DELAY", "REVERB"] && fx.slots.map(\.on) == [true, false, true])
    #expect(fx.slots[0].mix == 1 && fx.slots[0].params == ["cutoff": 0.3])
    #expect(fx.slots[1].mix == 0.7 && fx.slots[1].params == ["rate": 0.4])
    #expect(fx.slots[2].mix == 0.6 && fx.slots[2].params == ["size": 0.8, "hp": 0, "lp": 1, "send": 0])
    #expect(fx.dryWet == 0.5 && fx.effectKey == "FILTER > DELAY > REVERB")
    // andere Slot-Effekte: Beat-FX mit ihren Einstellungen, Roll ohne eigenen Filter; kaputte Slots → Standard
    let g = try decode(#"{"slots":[{"on":true,"amount":0.9},{"on":false,"amount":0.5},{"on":false,"amount":0.2}],"slotTypes":[4,1,5],"opts":{"GATER.rate":0.25,"GATER.mute":1,"ROLL.len":0.4,"ROLL.filter":0.2}}"#)
    #expect(g.slots.map(\.id) == ["GATER", "DELAY", "ROLL"] && g.slots[0].mix == 0.9 && g.slots[0].params == ["rate": 0.25])
    #expect(g.slots[2].mix == 1 && g.slots[2].params == ["len": 0.4, "filter": 0.5])
    let bad = try decode(#"{"dryWet":1,"slotTypes":[4,4,2]}"#)
    #expect(bad.slots.map(\.id) == ["FILTER", "DELAY", "REVERB"])
    #expect(try decode(#"{"dryWet":0.5}"#).effectKey == "FILTER > DELAY > REVERB")
}

/// SNGL → ein Slot mit den drei Parametern; Hall mit D/W als Send; Beat-FX aus den Einstellungen der Unit
@Test func oldSingleBecomesOneSlot() throws {
    let d = try decode(#"{"single":true,"singleType":1,"singleOn":true,"params":[0.3,0.6,0.4],"dryWet":0.8}"#)
    #expect(d.slots.count == 1 && d.slots[0].id == "DELAY" && d.slots[0].on && d.slots[0].mix == 1)
    #expect(d.slots[0].params == ["filter": 0.3, "feedback": 0.6, "rate": 0.4])
    let r = try decode(#"{"single":true,"singleType":2,"singleOn":false,"params":[0.7,0.3,0.8]}"#)
    #expect(r.slots[0].params == ["size": 0.7, "hp": 0.3, "lp": 0.8, "send": 1] && !r.slots[0].on)
    let f = try decode(#"{"single":true,"singleType":0,"params":[0.25,0.6,0.5]}"#)
    #expect(f.slots[0].params == ["cutoff": 0.25, "res": 0.6])
    let p = try decode(#"{"single":true,"singleType":7,"singleOn":true,"opts":{"PHASER.stages":1,"PHASER.freeze":1,"GATER.rate":0}}"#)
    #expect(p.slots[0].id == "PHASER" && p.slots[0].params == ["stages": 1])
}

/// PLUGIN-Kette → Plugin-Slots (an = Unit an und Platz an); versteckte Kette einer Unit im anderen Modus bleibt als Slots (aus)
@Test func oldChainBecomesPluginSlots() throws {
    let c = try decode(#"{"single":true,"singleType":3,"singleOn":true,"chain":[{"id":"aufx:a:b","on":true,"state":"AAE="},{"id":"aufx:c:d","on":false}],"pluginValues":{"p3":0.2,"s1.p4":0.7},"mapping":{"k1":"s1.p4"},"mappingKey":"aufx:a:b > aufx:c:d"}"#)
    #expect(c.slots.map(\.id) == ["aufx:a:b", "aufx:c:d"] && c.slots.map(\.on) == [true, false] && c.slots[0].state == Data([0, 1]))
    #expect(c.pluginValues == ["p3": 0.2, "s1.p4": 0.7] && c.mapping[.knob1] == "s1.p4" && c.mappingKey == "aufx:a:b > aufx:c:d")
    let off = try decode(#"{"single":true,"singleType":3,"singleOn":false,"chain":[{"id":"aufx:a:b"}]}"#)
    #expect(off.slots.map(\.on) == [false])
    // Single-REVERB mit einer Kette dahinter (vorher unsichtbar): Plugin wird Slot 2, aus; Werte rücken mit
    let h = try decode(#"{"single":true,"singleType":2,"singleOn":true,"params":[0.6,0.1,0.9],"chain":[{"id":"aufx:rivr:Xmpl","on":true,"state":"AAE="}],"pluginValues":{"p5":0.3},"mapping":{"k1":"lp"},"mappingKey":"REVERB"}"#)
    #expect(h.slots.map(\.id) == ["REVERB", "aufx:rivr:Xmpl"] && h.slots.map(\.on) == [true, false] && h.slots[1].state == Data([0, 1]))
    #expect(h.pluginValues == ["s1.p5": 0.3] && h.mapping[.knob1] == "lp" && h.mappingKey == "REVERB > aufx:rivr:Xmpl")
    // Gruppe mit Kette: drei eingebaute, dahinter die Plugins
    let g = try decode(#"{"single":false,"chain":[{"id":"aufx:a:b"},{"id":"aufx:c:d"}]}"#)
    #expect(g.slots.map(\.id) == ["FILTER", "DELAY", "REVERB", "aufx:a:b", "aufx:c:d"].prefix(MixEngine.slotCount).map { $0 })
}

/// gemerkte Belegungen der Gruppe: Kennung → Rack-Kennung, Ziele → Slot-Schlüssel; Single und Plugins bleiben
@Test func oldMappingsMigrate() {
    func m(_ t: [String: String]) -> FXMapping { var x = FXMapping(); x.targets = t; return x }
    let old: [String: FXMapping] = [
        "GROUP": m(["k1": "reverb.size", "b2": "delay.time", "k2": "filter", "b1": "filter.on", "k3": "delay", "dw": "dw", "b3": ""]),
        "GROUP:GATER/DELAY/ROLL": m(["k3": "roll", "b2": "gater.rate", "k1": "gater", "b3": "roll.rev"]),
        "DELAY": m(["k1": "rate", "b1": "on"]),
        "aufx:a:b > aufx:c:d": m(["k2": "s1.p4"]),
    ]
    let new = FXMigration.mappings(old)
    #expect(Set(new.keys) == ["FILTER > DELAY > REVERB", "GATER > DELAY > ROLL", "DELAY", "aufx:a:b > aufx:c:d"])
    #expect(new["FILTER > DELAY > REVERB"]?.targets == ["k1": "s2.size", "b2": "s1.rate", "k2": "cutoff", "b1": "on", "k3": "s1.mix", "dw": "dw", "b3": ""])
    #expect(new["GATER > DELAY > ROLL"]?.targets == ["k3": "s2.len", "b2": "rate", "k1": "mix", "b3": "s2.rev"])
    #expect(new["DELAY"] == old["DELAY"] && new["aufx:a:b > aufx:c:d"] == old["aufx:a:b > aufx:c:d"])
    #expect(FXMigration.mappings(new) == new)   // mehrfach aufrufbar
}

/// neue Fassung: Slots, Anteil, Parameter, Zustand über Speichern/Laden; Freeze/Mute nicht; Regeln beim Laden
@Test func slotsRoundTrip() throws {
    var fx = FXUnitState(slots: [FXSlot(id: "REVERB", on: true, mix: 0.4, params: ["size": 0.9, "freeze": 1]),
                                 FXSlot(id: "aufx:mrev:appl", on: false, state: Data([1, 2])), FXSlot(id: "GATER", params: ["mute": 1, "rate": 0.5])],
                         dryWet: 0.7)
    fx.mapping[.knob2] = "s2.rate"
    fx.mappingKey = fx.effectKey
    let back = try JSONDecoder().decode(FXUnitState.self, from: JSONEncoder().encode(fx))
    #expect(back.slots.map(\.id) == fx.slots.map(\.id) && back.slots.map(\.on) == [true, false, false] && back.slots[0].mix == 0.4)
    #expect(back.slots[0].params == ["size": 0.9] && back.slots[2].params == ["rate": 0.5] && back.slots[1].state == Data([1, 2]))
    #expect(back.dryWet == 0.7 && back.mapping == fx.mapping && back.mappingKey == "REVERB > aufx:mrev:appl > GATER")
    #expect(back.slots[0].uid != fx.slots[0].uid)   // Laufzeit-Kennung wird nicht gespeichert
    let dup = try decode(#"{"inserts":[{"id":"DELAY"},{"id":"DELAY"},{"id":"a:b:c"}]}"#)
    #expect(dup.slots.map(\.id) == ["DELAY", "a:b:c"] && dup.slots[0].on)
    let empty = try decode(#"{"inserts":[]}"#)
    #expect(empty.slots.isEmpty && empty.effectKey.isEmpty && !empty.anyOn)
}

/// Vorlagen und Ersetzen: Gruppe wie früher GRP, eingebauter Effekt schon im Rack → Plätze tauschen
@Test func templatesAndReplace() {
    #expect(FXTemplate.group.slots.map(\.id) == ["FILTER", "DELAY", "REVERB"] && FXTemplate.group.slots.map(\.mix) == [1, 0.5, 0.5])
    #expect(FXTemplate.slot("FILTER").params == ["res": 0.45] && !FXTemplate.slot("DELAY").on && FXTemplate.slot("aufx:a:b").on)
    var s = FXTemplate.group.slots
    s[0].on = true
    let perm = FXRules.replace(&s, at: 0, with: "REVERB")
    #expect(s.map(\.id) == ["REVERB", "DELAY", "FILTER"] && perm == [2, 1, 0] && s[2].on)
    let perm2 = FXRules.replace(&s, at: 1, with: "aufx:x:y")
    #expect(s.map(\.id) == ["REVERB", "aufx:x:y", "FILTER"] && perm2 == [0, nil, 2] && !s[1].on)
}
