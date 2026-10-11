import Foundation
import Testing
import MixCore
@testable import MixEngine
@testable import MixApp

// FX-Regler und -Tasten des Controllers gehen über die FX-Belegung (kein Sonderfall im Controller).

@MainActor @Test func controllerFXKnobsAndButtonsFollowMapping() {
    let core = MixController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let u = ControllerUnit(device: nil, info: .init(id: "FX", location: 0, left: 0, right: 1), manager: manager)
    func fx(_ i: Int) -> FXUnitState { core.snapshot().fx[i] }

    // Standard: linke Sektion = FX 1, Regler 1 = Filter-Stärke, Taste 1 = Filter an/aus, D/W = Unit
    manager.handle(.fxKnob(0, 1, 0.8), unit: u)
    manager.handle(.fxKnob(0, 0, 0.6), unit: u)
    manager.handle(.fxButton(0, 1, true), unit: u)
    manager.handle(.fxButton(0, 1, false), unit: u)
    #expect(fx(0).slots[0].amount == 0.8 && fx(0).dryWet == 0.6 && fx(0).slots[0].on)

    // umbelegt: Regler 1 = Raumgröße, Taste 2 = Delay-Zeit, Taste 3 aus, D/W = Delay-Stärke
    core.setFXMapping(0, .knob1, "reverb.size")
    core.setFXMapping(0, .button2, "delay.time")
    core.setFXMapping(0, .button3, "")
    core.setFXMapping(0, .dryWet, "delay")
    let delayIndex = fx(0).delayIndex, reverbOn = fx(0).slots[2].on
    manager.handle(.fxKnob(0, 1, 0.25), unit: u)
    manager.handle(.fxKnob(0, 0, 0.9), unit: u)
    manager.handle(.fxButton(0, 2, true), unit: u)
    manager.handle(.fxButton(0, 3, true), unit: u)
    #expect(fx(0).reverbSize == 0.25 && fx(0).slots[0].amount == 0.8)
    #expect(fx(0).slots[1].amount == 0.9 && fx(0).dryWet == 0.6)
    #expect(fx(0).delayIndex == (delayIndex + 1) % MixEngine.delayBeats.count && fx(0).slots[2].on == reverbOn)

    // rechte Sektion = FX 2 mit eigener (Standard-)Belegung; Single: Taste 1 = an/aus, Mode bleibt Mode
    core.updateFX(1) { $0.single = true; $0.singleType = FXUnitState.Effect.reverb.rawValue }
    manager.handle(.fxKnob(1, 3, 0.7), unit: u)
    manager.handle(.fxButton(1, 1, true), unit: u)
    #expect(fx(1).params[2] == 0.7 && fx(1).singleOn)
    manager.handle(.fxButton(1, 0, true), unit: u)
    #expect(!fx(1).singleOn)
    manager.handle(.fxButton(1, 2, true), unit: u)   // Taste 2: in Single standardmäßig frei
    #expect(!fx(1).singleOn && fx(1).params == core.snapshot().fx[1].params)
}

/// Beat-FX über den Controller: Gruppe mit Gater/Flanger, Single-Phaser, Shift + Mode schaltet in Menü-Reihenfolge weiter
@MainActor @Test func controllerBeatFX() {
    let core = MixController()
    let manager = ControllerManager(core: core, status: ControllerStatus())
    let u = ControllerUnit(device: nil, info: .init(id: "FX", location: 0, left: 0, right: 1), manager: manager)
    func fx(_ i: Int) -> FXUnitState { core.snapshot().fx[i] }
    core.updateFX(0) { $0.setSlot(0, .gater); $0.setSlot(1, .flanger) }
    manager.handle(.fxKnob(0, 1, 0.9), unit: u)
    manager.handle(.fxKnob(0, 2, 0.3), unit: u)
    manager.handle(.fxButton(0, 1, true), unit: u)
    manager.handle(.fxButton(0, 2, true), unit: u)
    #expect(fx(0).slots[0].amount == 0.9 && fx(0).slots[0].on && fx(0).slots[1].amount == 0.3 && fx(0).slots[1].on)
    core.updateFX(1) { $0.single = true; $0.singleType = FXUnitState.Effect.phaser.rawValue }
    manager.handle(.fxButton(1, 1, true), unit: u)
    manager.handle(.fxButton(1, 2, true), unit: u)
    manager.handle(.fxButton(1, 3, true), unit: u)
    #expect(fx(1).singleOn && fx(1).opts["PHASER.freeze"] == 1 && fx(1).opts["PHASER.stages"] == 1)
    u.shift = true
    manager.handle(.fxButton(1, 0, true), unit: u)
    u.shift = false
    #expect(fx(1).singleType == FXUnitState.Effect.plugin.rawValue)
}
