import Testing
import MixEngine

@Test func usbInterfaceOnAnotherPortIsFound() {
    let old = "AppleUSBAudioEngine:Allen and Heath:XONE 96 USB 1:2111000:1,2"
    let now = ["BuiltInSpeakerDevice", "AppleUSBAudioEngine:Allen and Heath:XONE 96 USB 1:1111000:1,2",
               "AppleUSBAudioEngine:Allen and Heath:XONE 96 USB 2:1112000:1,2", "AppleUSBAudioEngine:Steinberg:UR22C:3100000:1,2"]
    #expect(MixEngine.relocatedUID(old, among: now) == "AppleUSBAudioEngine:Allen and Heath:XONE 96 USB 1:1111000:1,2")
    // zwei gleiche Geräte: nicht raten
    #expect(MixEngine.relocatedUID(old, among: now + ["AppleUSBAudioEngine:Allen and Heath:XONE 96 USB 1:3111000:1,2"]) == nil)
    // Nicht-USB nie zuordnen, gleiche UID ist kein Umzug
    #expect(MixEngine.relocatedUID("BuiltInSpeakerDevice", among: now) == nil)
    #expect(MixEngine.relocatedUID(now[1], among: now) == nil)
}
