import Foundation
import IOKit.pwr_mgt

/// LIVE: der Mac bleibt wach – kein Ruhezustand, kein Bildschirmschoner, Display bleibt an. Zugeklappt hält macOS
/// einen Laptop nur mit Netzteil + externem Bildschirm wach (oder `pmset disablesleep`, braucht Admin)
@MainActor
enum LiveMode {
    private static var ids: [IOPMAssertionID] = []
    private static var activity: NSObjectProtocol?

    static func set(_ on: Bool) {
        for id in ids { IOPMAssertionRelease(id) }
        ids = []
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        guard on else { return }
        let reason = "MINOS-741 LIVE" as CFString
        for type in [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep, kIOPMAssertionTypePreventSystemSleep] {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id) == kIOReturnSuccess { ids.append(id) }
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled, .latencyCritical],
                                                         reason: "MINOS-741 LIVE")
    }
}
