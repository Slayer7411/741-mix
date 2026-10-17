import Foundation
import Testing
@testable import MixCore

@Test func codenamePerMajor() {
    let expected = ["LIMBUS", "LUXURIA", "GULA", "AVARITIA", "IRA", "HAERESIS",
                    "VIOLENTIA", "FRAUS", "PRODITIO", "PURGATORIUM", "PARADISUS"]
    for (major, name) in expected.enumerated() {
        #expect(Codename.name(major: major) == name)
    }
}

@Test func codenameBeyondTenIsParadisus() {
    #expect(Codename.name(major: 11) == "PARADISUS")
    #expect(Codename.name(major: 99) == "PARADISUS")
}

@Test func codenameNegativeMajorClampsToFirst() {
    #expect(Codename.name(major: -1) == "LIMBUS")
}

@Test func codenameForVersion() {
    #expect(Codename.forVersion("0.8.2") == "LIMBUS")
    #expect(Codename.forVersion("0.0.0") == "LIMBUS")
    #expect(Codename.forVersion("1.0.0") == "LUXURIA")
    #expect(Codename.forVersion("2.4") == "GULA")
    #expect(Codename.forVersion("3") == "AVARITIA")
    #expect(Codename.forVersion("9.1.0") == "PURGATORIUM")
    #expect(Codename.forVersion("10.0.0") == "PARADISUS")
    #expect(Codename.forVersion("12.3.4") == "PARADISUS")
    #expect(Codename.forVersion("v4.0.1") == "IRA")
    #expect(Codename.forVersion("08.1") == "PRODITIO")
}

@Test func codenameForMalformedVersionIsNil() {
    let bad = ["", "v", "x", "1..2", ".1", "1.", "-1.0", "+1.0", "1.2.3.4", "0.8.2-rc1", "0.8.a",
               " 0.8.2", "0.8.2 ", "1,0", "99999999999999999999.0", "vv1.0", "1.0.0\n"]
    for v in bad {
        #expect(Codename.forVersion(v) == nil, "\(v.debugDescription)")
        #expect(Codename.major(of: v) == nil, "\(v.debugDescription)")
    }
}

/// scripts/codename.sh hält eine Kopie der Liste; sie muss dieselbe Reihenfolge haben
@Test func codenameShellCopyMatches() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = try String(contentsOf: root.appendingPathComponent("scripts/codename.sh"), encoding: .utf8)
    #expect(script.contains("names=(\(Codename.names.joined(separator: " ")))"))
}
