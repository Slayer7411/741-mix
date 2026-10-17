import Foundation
import Testing
@testable import MixCore

// Ende-zu-Ende-Modus aus: ohne MIX741_E2E_ROOT bleibt alles beim Alten (Pfade, Suite, Bonjour-Art)

@Suite("E2E-Konfiguration ohne MIX741_E2E_ROOT")
struct E2EConfigTests {
    @Test func inactiveWithoutRoot() {
        // Die Testläufe setzen die Variable nicht; sonst wäre der Test sinnlos
        guard ProcessInfo.processInfo.environment["MIX741_E2E_ROOT"] == nil else { return }
        #expect(!E2E.isActive)
        #expect(E2E.root == nil)
        #expect(E2E.collection == nil)
        #expect(E2E.music == nil)
        #expect(E2E.control == nil)
        #expect(E2E.shared == nil)
        #expect(E2E.defaults === UserDefaults.standard)
        #expect(E2E.applicationSupport == FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
        #expect(E2E.caches == FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }

    @Test func suiteNameIsSafe() {
        let n = E2E.suite
        #expect(n.hasPrefix("com.github.slayer7411.minos741.e2e."))
        #expect(!n.contains("/") && !n.contains(" "))
    }

    @Test func peerPortsNeedSharedFolder() {
        // ohne gemeinsamen Ordner gibt es keine Portmeldung (Verbindung läuft dann nicht über Loopback)
        guard E2E.shared == nil else { return }
        #expect(E2EPeers.port(of: "irgendwer") == nil)
    }
}
