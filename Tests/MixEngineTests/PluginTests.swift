import Foundation
import Testing
import MixEngine

/// Plugin-Liste, Parameter und Zustand (ClassInfo) über die Swift-Seite
@Test func pluginListParametersAndState() throws {
    let list = PluginHost.installed()
    let info = try #require(list.first { $0.id == "aufx:mrev:appl" })
    #expect(info.name == "AUMatrixReverb" && info.manufacturer == "Apple")
    #expect(PluginHost.codes(info.id).map { $0.1 } == info.subtype)
    let a = try PluginInstance(info, sampleRate: 48000)
    #expect(a.parameters.count >= 3)
    a.setKnob(0, 0.25)
    let k = try #require(a.knob(0))
    #expect(abs(k - 0.25) < 0.01)
    let st = try #require(a.state)
    let b = try PluginInstance(info, sampleRate: 48000)
    b.state = st
    #expect(abs((b.knob(0) ?? -1) - 0.25) < 0.01)
}
