import Foundation
import Testing
import MixCore

private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

@Test func statusExpiryPerLevel() {
    var log = StatusLog()
    log.post(.info, "info", now: t0)
    log.post(.ok, "ok", now: t0)
    log.post(.warning, "warnung", now: t0)
    log.post(.error, "fehler", now: t0)
    #expect(log.active.count == 4)
    #expect(log.nextExpiry == t0.addingTimeInterval(3))
    log.expire(now: t0.addingTimeInterval(3.01))
    #expect(log.active.map(\.text) == ["info", "warnung", "fehler"])
    log.expire(now: t0.addingTimeInterval(4.01))
    #expect(log.active.map(\.text) == ["warnung", "fehler"])
    log.expire(now: t0.addingTimeInterval(8.01))
    #expect(log.active.map(\.text) == ["fehler"])
    // Fehler bleibt, bis er weggeklickt oder ersetzt wird
    log.expire(now: t0.addingTimeInterval(3600))
    #expect(log.active.map(\.text) == ["fehler"])
    log.dismiss(id: log.active[0].id)
    #expect(log.active.isEmpty)
    #expect(log.history.count == 4)
}

@Test func statusDedupeByKeyReplacesInPlace() {
    var log = StatusLog()
    log.post(.info, "andere", key: "x", now: t0)
    let id = log.post(.info, "Export 1/10", key: "export", progress: 0.1, progressText: "1/10", now: t0)
    log.post(.info, "dritte", now: t0.addingTimeInterval(0.5))
    for n in 2...10 {
        let again = log.post(.info, "Export \(n)/10", key: "export", progress: Double(n) / 10, progressText: "\(n)/10",
                             now: t0.addingTimeInterval(Double(n)))
        #expect(again == id)
    }
    // an ihrer Stelle ersetzt, nicht angehängt; Verlauf hat sie einmal
    #expect(log.active.map(\.key) == ["x", "export", nil])
    #expect(log.active[1].text == "Export 10/10")
    #expect(log.active[1].progress == 1)
    #expect(log.history.filter { $0.key == "export" }.count == 1)
    #expect(log.history.count == 3)
    // Ablauf zählt ab der letzten Aktualisierung
    log.expire(now: t0.addingTimeInterval(13.9))
    #expect(log.active.contains { $0.key == "export" })
    log.expire(now: t0.addingTimeInterval(14.1))
    #expect(!log.active.contains { $0.key == "export" })
    // Fehler mit Schlüssel ersetzt die Fortschrittsmeldung und bleibt
    log.post(.info, "läuft", key: "load.0", now: t0)
    log.post(.error, "nicht ladbar", key: "load.0", now: t0.addingTimeInterval(1))
    #expect(log.active.filter { $0.key == "load.0" }.count == 1)
    log.expire(now: t0.addingTimeInterval(100))
    #expect(log.active.first { $0.key == "load.0" }?.level == .error)
}

@Test func statusOrderingCurrentAndHistory() {
    var log = StatusLog()
    log.post(.info, "a", now: t0)
    #expect(log.current?.text == "a")
    log.post(.ok, "b", now: t0.addingTimeInterval(1))
    #expect(log.current?.text == "b")   // gleiche Stufe (ok = info): die neueste
    log.post(.error, "fehler", now: t0.addingTimeInterval(2))
    log.post(.info, "c", now: t0.addingTimeInterval(3))
    #expect(log.current?.text == "fehler")   // Fehler vor Info, auch wenn älter
    log.post(.warning, "w", now: t0.addingTimeInterval(4))
    #expect(log.current?.text == "fehler")
    log.dismiss(id: log.current!.id)
    #expect(log.current?.text == "w")
    // Verlauf: neueste zuerst, höchstens 50
    #expect(log.history.map(\.text) == ["w", "c", "fehler", "b", "a"])
    for i in 0..<80 { log.post(.info, "n\(i)", now: t0.addingTimeInterval(10 + Double(i))) }
    #expect(log.history.count == 50)
    #expect(log.history.first?.text == "n79")
    #expect(log.history.last?.text == "n30")
}

@Test func statusJobRunsWithoutExpiryAndHandsOverToDoneMessage() {
    var log = StatusLog()
    let id = log.post(.info, "Analyse", key: "analysis", progress: 0.1, progressText: "1/10", job: true, now: t0)
    log.post(.info, "Analyse", key: "analysis", progress: 0.5, progressText: "5/10", job: true, now: t0.addingTimeInterval(9))
    #expect(log.jobCount == 1)
    #expect(log.nextExpiry == nil)
    log.expire(now: t0.addingTimeInterval(3600))
    #expect(log.active.map(\.id) == [id])
    #expect(log.active.first?.progress == 0.5)
    // Schlussmeldung ersetzt den Job an seiner Stelle: 3 s, kein Job mehr
    log.post(.ok, "Analysiert: 3 Tracks", key: "analysis", now: t0.addingTimeInterval(3601))
    #expect(log.jobCount == 0)
    #expect(log.active.map(\.id) == [id])
    #expect(log.nextExpiry == t0.addingTimeInterval(3604))
}

@Test func statusJobsCountSeparately() {
    var log = StatusLog()
    log.post(.info, "Analyse", key: "analysis", job: true, now: t0)
    log.post(.info, "Schneiden", key: "cut", job: true, now: t0)
    log.post(.warning, "Datei fehlt", key: "load.0", now: t0)
    #expect(log.jobCount == 2)
    #expect(log.current?.text == "Datei fehlt")
}
