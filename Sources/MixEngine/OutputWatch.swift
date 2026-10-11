import Foundation

/// Zustand der Audio-Ausgabe gegenüber dem Gerät: Ereignisse rein, Aktion raus. Ohne CoreAudio (testbar);
/// die Engine führt die Aktionen auf ihrer Geräte-Queue aus.
/// Gerät weg -> anhalten, auf dasselbe Gerät (UID) warten, dann neu öffnen. Ratenwechsel -> neu öffnen
/// (Geräterate bleibt, wie sie ist), Pufferwechsel -> Werte neu lesen. Ruhezustand -> anhalten, nach dem Aufwachen neu öffnen.
public struct OutputWatch: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        /// nie gestartet oder bewusst angehalten
        case stopped
        case running
        /// Gerät weg (oder nach dem Aufwachen noch nicht da): wartet auf dieselbe UID
        case waiting
        case sleeping
    }

    public enum Event: Sendable, Equatable {
        case started(uid: String, rate: Double, buffer: UInt32)
        case startFailed
        /// bewusst angehalten (Oberfläche, Beenden)
        case stopped
        /// kAudioDevicePropertyDeviceIsAlive des laufenden Geräts
        case alive(Bool)
        /// Geräteliste geändert oder Takt beim Warten: unsere UID da und lebendig?
        case present(Bool)
        case rate(Double)
        case buffer(UInt32)
        case willSleep
        case didWake
    }

    public enum Action: Sendable, Equatable {
        case none
        /// Ausgabe anhalten (Gerät weg, Ruhezustand)
        case stop
        /// Gerät mit `uid` neu öffnen (Rückkehr, Aufwachen, Ratenwechsel)
        case reopen
        /// Latenz und Puffer neu lesen
        case reread
    }

    public private(set) var phase = Phase.stopped
    /// Gerät, auf das gewartet bzw. das gespielt wird
    public private(set) var uid: String?
    public private(set) var rate = 0.0
    public private(set) var buffer: UInt32 = 0
    /// automatisch wieder verbunden (Rückkehr, Aufwachen)
    public private(set) var reconnects = 0
    public private(set) var rateChanges = 0
    public private(set) var bufferChanges = 0

    public init() {}

    /// wartet auf ein Gerät (Polling an)
    public var waiting: Bool { phase == .waiting }
    /// Ausgabe soll laufen (spielt oder wartet auf das Gerät): App Nap aus
    public var wanted: Bool { phase == .running || phase == .waiting }

    public mutating func handle(_ e: Event) -> Action {
        switch e {
        case let .started(uid, rate, buffer):
            if phase == .waiting || phase == .sleeping, uid == self.uid { reconnects += 1 }
            phase = .running; restarting = false
            self.uid = uid; self.rate = rate; self.buffer = buffer
            return .none
        case .startFailed:
            // Neuverbinden fehlgeschlagen: weiter warten; Start von Hand fehlgeschlagen: steht
            phase = phase == .waiting || phase == .sleeping || restarting ? .waiting : .stopped
            restarting = false
            return .none
        case .stopped:
            phase = .stopped
            return .none
        case .alive(false), .present(false):
            guard phase == .running else { return .none }
            phase = .waiting
            return .stop
        case .alive(true), .present(true):
            return phase == .waiting ? .reopen : .none
        case let .rate(r):
            guard phase == .running, r > 0, abs(r - rate) > 0.5 else { return .none }
            rate = r; rateChanges += 1; restarting = true
            return .reopen
        case let .buffer(b):
            guard phase == .running, b > 0, b != buffer else { return .none }
            buffer = b; bufferChanges += 1
            return .reread
        case .willSleep:
            guard wanted else { return .none }
            phase = .sleeping
            return .stop
        case .didWake:
            guard phase == .sleeping else { return .none }
            phase = .waiting
            return .reopen
        }
    }

    /// Neustart wegen Ratenwechsel läuft (scheitert er, wird gewartet statt aufgegeben)
    private var restarting = false
}
