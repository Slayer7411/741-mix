import Foundation

/// MIDI-Clock (24 Takte je Viertel) mit Transport und Song Position. Reine Planung in Beats, ohne CoreMIDI:
/// der Aufrufer (MixEngine) rechnet Beats mit dem Tempo des Takts in Host-Zeit um und sendet mit Zeitstempel.
public enum MIDIClock {
    public static let ticksPerBeat = 24
    /// Systemechtzeit-Bytes (MIDI 1.0)
    public static let clockByte: UInt8 = 0xF8, startByte: UInt8 = 0xFA, continueByte: UInt8 = 0xFB, stopByte: UInt8 = 0xFC
    public static let songPositionByte: UInt8 = 0xF2

    /// Nachricht mit 1 bis 3 Bytes
    public struct Message: Equatable, Sendable {
        public var bytes: [UInt8]
        public static func realtime(_ b: UInt8) -> Message { Message(bytes: [b]) }
        /// Song Position Pointer: Einheit = Sechzehntel (6 Takte), 14 Bit, LSB zuerst
        public static func songPosition(sixteenths: Int) -> Message {
            let v = min(max(sixteenths, 0), 16383)
            return Message(bytes: [songPositionByte, UInt8(v & 0x7F), UInt8(v >> 7 & 0x7F)])
        }
    }

    /// geplantes Ereignis: Beat (Master-Clock), an dem es hörbar sein soll
    public struct Event: Equatable, Sendable {
        public var beat: Double
        public var message: Message
    }

    /// Beat des Takts k (Takt 0 = Beat 0)
    public static func beat(ofTick k: Int64) -> Double { Double(k) / Double(ticksPerBeat) }

    /// erster Takt, dessen Beat nicht vor `beat` liegt (kleine Toleranz gegen Rundung)
    public static func tick(atOrAfter beat: Double) -> Int64 {
        Int64((beat * Double(ticksPerBeat) - 1e-6).rounded(.up))
    }

    /// Sekunden zwischen zwei Beats bei gegebenem Tempo (BPM)
    public static func seconds(fromBeat a: Double, toBeat b: Double, bpm: Double) -> Double {
        (b - a) * 60 / bpm
    }

    /// Sechzehntel-Index (Song Position) zu einem Takt, abgerundet auf die Sechzehntel-Grenze
    public static func sixteenth(ofTick k: Int64) -> Int { Int(max(0, k) / 6) }
}

/// Zustand des Senders: Transport (Start/Continue/Stop) und fortlaufende Takte. Ein Aufruf je Takt der Queue.
public struct MIDIClockPlanner: Sendable {
    /// Song Position beim Start/Einrasten senden (sonst Start bei Takt 0 und die Zählung beginnt bei Start)
    public var songPosition: Bool
    /// läuft der Transport gerade
    public private(set) var running = false
    /// Index des zuletzt geplanten Takts
    private var last: Int64?
    /// nach einem Start nicht gleich wieder einrasten (der Start selbst setzt die Position)
    private var justStarted = false

    public init(songPosition: Bool = true) { self.songPosition = songPosition }

    /// Ereignisse für das Fenster ab `beatNow` über `ahead` Beats.
    /// `playing`: Transport läuft (Start beim Übergang nach oben, Stop nach unten).
    /// Springt die Clock (mehr als zwei Takte vor/zurück), wird neu eingerastet: Song Position + Continue.
    public mutating func plan(beatNow: Double, playing: Bool, ahead: Double) -> [MIDIClock.Event] {
        var out: [MIDIClock.Event] = []
        if playing && !running {
            running = true
            let k = MIDIClock.tick(atOrAfter: beatNow)
            if songPosition && k > 0 {
                // Position auf der Sechzehntel-Grenze: Takte ab dort (die vor „jetzt“ liegenden werden sofort gesendet)
                let s = MIDIClock.sixteenth(ofTick: k)
                out.append(.init(beat: beatNow, message: .songPosition(sixteenths: s)))
                out.append(.init(beat: beatNow, message: .realtime(MIDIClock.continueByte)))
                last = Int64(s * 6) - 1
            } else {
                out.append(.init(beat: beatNow, message: .realtime(MIDIClock.startByte)))
                last = k - 1
            }
            justStarted = true
        } else if !playing && running {
            // Stop nach dem letzten schon geplanten Takt (sonst käme er vor Takten, die bis Vorlauf voraus liegen)
            let stopBeat = max(beatNow, last.map { MIDIClock.beat(ofTick: $0 + 1) } ?? beatNow)
            running = false
            last = nil
            justStarted = false
            return [.init(beat: stopBeat, message: .realtime(MIDIClock.stopByte))]
        }
        guard running else { return out }

        let now = MIDIClock.tick(atOrAfter: beatNow)
        var next = last.map { $0 + 1 } ?? now
        if justStarted {
            justStarted = false
        } else if next < now - 2 || next > now + Int64((ahead * Double(MIDIClock.ticksPerBeat)).rounded(.up)) + 4 {
            // Clock gesprungen oder Queue zu spät: neu einrasten
            next = now
            if songPosition {
                out.append(.init(beat: beatNow, message: .songPosition(sixteenths: MIDIClock.sixteenth(ofTick: next))))
                out.append(.init(beat: beatNow, message: .realtime(MIDIClock.continueByte)))
                next = Int64(MIDIClock.sixteenth(ofTick: next) * 6)
            }
        }
        let end = beatNow + ahead
        var k = next
        while MIDIClock.beat(ofTick: k) < end {
            out.append(.init(beat: MIDIClock.beat(ofTick: k), message: .realtime(MIDIClock.clockByte)))
            k += 1
        }
        last = k - 1
        return out
    }

    /// Transport beenden (ohne Planung): Stop-Ereignis, wenn er lief
    public mutating func halt(beatNow: Double) -> [MIDIClock.Event] {
        guard running else { return [] }
        return plan(beatNow: beatNow, playing: false, ahead: 0)
    }
}
