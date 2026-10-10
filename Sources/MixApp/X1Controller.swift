import Foundation
import IOKit.hid
import Observation
import MixCore
import MixEngine

/// Anzeige-Seite für die Einstellungen (Hauptthread)
@MainActor @Observable
final class X1Status {
    struct Info: Identifiable, Hashable {
        let id: String          // Seriennummer
        let location: Int
        var left: Int           // Deck-Index der linken Seite
        var right: Int
        /// welcher Browser-Bereich: 0 = links/oben, 1 = rechts/unten
        var pane: Int = 0
        /// FX-Sektionen: -1 = FX1/FX2, 0 = beide FX1, 1 = beide FX2, 10 = FX1/FX3, 11 = FX2/FX4
        var fxUnit: Int = -1
    }
    var devices: [Info] = []
    var lastEvent = ""
    @ObservationIgnored weak var manager: X1Manager?

    func assign(_ serial: String, left: Int, right: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].left = left
        devices[i].right = right
        UserDefaults.standard.set([left, right], forKey: "x1.\(serial)")
        manager?.assign(serial, left: left, right: right)
    }

    func assignPane(_ serial: String, _ pane: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].pane = pane
        UserDefaults.standard.set(pane, forKey: "x1pane.\(serial)")
        manager?.assignPane(serial, pane)
    }

    func assignFX(_ serial: String, _ unit: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].fxUnit = unit
        UserDefaults.standard.set(unit, forKey: "x1fx.\(serial)")
        manager?.assignFX(serial, unit)
    }

    func identify(_ serial: String) { manager?.identify(serial) }
}

/// Traktor Kontrol X1 MK2 im nativen HID-Modus (VID 0x17cc, PID 0x1220).
/// Läuft komplett auf der Steuer-Queue des Kerns – unabhängig von der Oberfläche.
/// Protokoll: Input-Report 0x01 (Tasten/Regler), Output 0x80 (Tasten-LEDs, RGB-Pads), 0x81 (7-Segment, Touchstrip).
/// Byte-Positionen nach dem Mixxx-HID-Mapping von infiniteloop; Belegung nach NI-Standard
/// plus Christians eigene Traktor-Zuordnungen (aus Traktor Settings.tsi), alles in den Einstellungen änderbar.
final class X1Manager: @unchecked Sendable {
    let core: MixController
    let status: X1Status
    private var manager: IOHIDManager?
    fileprivate var units: [String: X1Unit] = [:]
    private let lock = NSLock()
    private var _prefs = X1Prefs()
    /// 2 oder 4 FX-Units (aus den Einstellungen)
    var fxUnits = 2
    // gebündelte Browse-Schritte (nur auf der Steuer-Queue anfassen)
    private var pendingBrowse: [Int: Int] = [:]
    private var browseScheduled = false
    /// Browser-Aktionen (laufen auf dem Hauptthread)
    /// Browser-Aktionen je Bereich (pane), laufen auf dem Hauptthread
    var onBrowse: (@MainActor (_ pane: Int, _ step: Int) -> Void)?
    var onLoad: (@MainActor (_ pane: Int, _ deck: Int) -> Void)?
    var onPreview: (@MainActor (_ pane: Int) -> Void)?
    var onToggleBrowser: (@MainActor () -> Void)?

    /// Standard: erstes X1 (nach USB-Position) steuert A/C, das zweite B/D – pro Gerät in den Einstellungen änderbar.
    static let defaultAssignments: [(Int, Int)] = [(0, 2), (1, 3), (0, 1), (2, 3)]

    var prefs: X1Prefs {
        get { lock.lock(); defer { lock.unlock() }; return _prefs }
        set { lock.lock(); _prefs = newValue; lock.unlock() }
    }

    @MainActor init(core: MixController, status: X1Status) {
        self.core = core
        self.status = status
        status.manager = self
    }

    func start() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x17cc, kIOHIDProductIDKey: 0x1220] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<X1Manager>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<X1Manager>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        // Reports zentral über den Manager (pro Gerät ist das nach Activate nicht erlaubt)
        IOHIDManagerRegisterInputReportCallback(m, { ctx, _, sender, _, _, report, len in
            let me = Unmanaged<X1Manager>.fromOpaque(ctx!).takeUnretainedValue()
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            me.units.values.first { $0.device == device }?.parse(Array(UnsafeBufferPointer(start: report, count: len)))
        }, ctx)
        // HID-Ereignisse direkt auf der Steuer-Queue, nicht auf dem Hauptthread
        IOHIDManagerSetDispatchQueue(m, core.controlQueue)
        // ohne Open kommen keine Input-Reports an
        let st = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        print("[x1] HID-Manager geöffnet: \(st)")
        IOHIDManagerActivate(m)
        manager = m
        core.addTickHandler { [weak self] c in self?.refreshLEDs(c) }
    }

    private func attach(_ device: IOHIDDevice) {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? UUID().uuidString
        let loc = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        guard units[serial] == nil else { return }
        let saved = UserDefaults.standard.array(forKey: "x1.\(serial)") as? [Int]
        let def = Self.defaultAssignments[min(units.count, Self.defaultAssignments.count - 1)]
        let savedPane = UserDefaults.standard.object(forKey: "x1pane.\(serial)") as? Int
        var info = X1Status.Info(id: serial, location: loc, left: saved?.first ?? def.0, right: saved?.last ?? def.1,
                                 pane: savedPane ?? min(units.count, 1))
        // Standard wie Traktor mit 2 X1: Seite mit A/C steuert FX1 (+FX3), mit B/D FX2 (+FX4)
        info.fxUnit = UserDefaults.standard.object(forKey: "x1fx.\(serial)") as? Int
            ?? ([0, 2].contains(info.left) || [0, 2].contains(info.right) ? 10 : 11)
        units[serial] = X1Unit(device: device, info: info, manager: self)
        DispatchQueue.main.async {
            self.status.devices.append(info)
            self.status.devices.sort { $0.location < $1.location }
            self.status.lastEvent = "X1 \(serial) verbunden"
        }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let (k, _) = units.first(where: { $0.value.device == device }) else { return }
        units[k] = nil
        DispatchQueue.main.async {
            self.status.devices.removeAll { $0.id == k }
            self.status.lastEvent = "X1 \(k) getrennt"
        }
    }

    func assign(_ serial: String, left: Int, right: Int) {
        core.controlQueue.async { self.units[serial]?.info.left = left; self.units[serial]?.info.right = right }
    }

    func assignPane(_ serial: String, _ pane: Int) {
        core.controlQueue.async { self.units[serial]?.info.pane = pane }
    }

    func assignFX(_ serial: String, _ unit: Int) {
        core.controlQueue.async { self.units[serial]?.info.fxUnit = unit }
    }

    func identify(_ serial: String) {
        core.controlQueue.async { self.units[serial]?.flashUntil = Date().addingTimeInterval(1.5) }
    }

    private func refreshLEDs(_ c: MixController) {
        let s = c.snapshot(), p = prefs
        for u in units.values { u.sendLEDs(state: s, prefs: p) }
    }

    // MARK: - Ereignisse von einem X1 (Steuer-Queue)

    /// welche FX-Unit eine Sektion (0 = links, 1 = rechts) dieses X1 steuert
    func fxUnit(_ unit: X1Unit, section s: Int) -> Int? {
        let n = fxUnits
        let u: Int = switch unit.info.fxUnit {
        case 0: 0
        case 1: 1
        case 10: n == 4 ? [0, 2][s] : 0
        case 11: n == 4 ? [1, 3][s] : 1
        default: s
        }
        return u < n ? u : nil
    }

    func handle(_ e: X1Unit.Event, unit: X1Unit) {
        let p = prefs
        let deck: (X1Unit.Side) -> Int = { $0 == .left ? unit.info.left : unit.info.right }
        let text = "\(unit.info.id): " + String(describing: e).replacingOccurrences(of: "MixApp.X1Unit.Side.", with: "")
        DispatchQueue.main.async { self.status.lastEvent = text }
        print("[x1] \(text)")
        fflush(stdout)
        switch e {
        case let .play(s, down):
            if down { unit.shift ? core.cup(deck(s)) : core.togglePlay(deck(s)) }
        case let .cue(s, down):
            let d = deck(s)
            let normal = unit.shift || p.cueAction == .cue
            if normal || unit.cueAsNormal[s] == true {
                if down { unit.cueAsNormal[s] = true; core.cueDown(d) } else { unit.cueAsNormal[s] = nil; core.cueUp(d) }
            } else if p.cueAction == .reverse {
                core.setReverse(d, down)
            } else {
                core.fluxReverse(d, on: down)
            }
        case let .sync(s, down):
            // Antippen = Sync; gehalten + 3/4 = einen Takt zurück/vor (Sync schaltet dann nicht)
            if down {
                if unit.shift { core.toggleMaster(deck(s)) } else { unit.syncHeld[s] = true; unit.syncComboUsed[s] = false }
            } else if unit.syncHeld[s] == true {
                if unit.syncComboUsed[s] != true { core.toggleSync(deck(s)) }
                unit.syncHeld[s] = false
            }
        case let .flux(s, down):
            // Antippen = Flux-Modus; gehalten = Ebene für Hotcue 3/4 (Beatjump)
            if down {
                unit.fluxHeld[s] = true
                unit.fluxComboUsed[s] = false
            } else {
                if p.fluxTapToggles, unit.fluxComboUsed[s] != true { core.toggleFlux(deck(s)) }
                unit.fluxHeld[s] = false
            }
        case let .hotcue(s, n, down):
            guard down else { return }
            let d = deck(s)
            if unit.syncHeld[s] == true, n == 2 || n == 3 {
                unit.syncComboUsed[s] = true
                core.barJump(d, bars: n == 2 ? -1 : 1)
            } else if unit.fluxHeld[s] == true, n == 2 || n == 3 {
                unit.fluxComboUsed[s] = true
                core.beatjump(d, beats: (n == 2 ? -1 : 1) * p.fluxBeatjumpBeats)
            } else {
                core.hotcue(d, n, delete: unit.shift)
            }
        case let .loopTurn(s, delta):
            let d = deck(s)
            if unit.shift { core.beatjump(d, beats: Double(delta) * core.snapshot().decks[d].jumpSize) }
            else { core.changeLoopSize(d, by: delta) }
        case let .loopPush(s, down):
            if down { unit.shift ? core.reloop(deck(s)) : core.autoLoop(deck(s)) }
        case let .load(s, down):
            if down { let d = deck(s), pane = unit.info.pane; DispatchQueue.main.async { self.onLoad?(pane, d) } }
        case let .browseTurn(delta):
            // Schritte sammeln und gebündelt an die Oberfläche geben (kein Stau bei schnellem Drehen)
            let pane = unit.info.pane
            pendingBrowse[pane, default: 0] += delta * (unit.shift ? p.browseFastStep : 1)
            if !browseScheduled {
                browseScheduled = true
                DispatchQueue.main.async {
                    let steps = self.core.controlQueue.sync { () -> [Int: Int] in
                        let s = self.pendingBrowse
                        self.pendingBrowse = [:]
                        self.browseScheduled = false
                        return s
                    }
                    for (pn, st) in steps where st != 0 { self.onBrowse?(pn, st) }
                }
            }
        case let .browsePush(down):
            // Drücken = Browser groß/klein (wie Traktor), Shift + Drücken = Vorhören
            guard down else { return }
            let pane = unit.info.pane
            if unit.shift { DispatchQueue.main.async { self.onPreview?(pane) } }
            else { DispatchQueue.main.async { self.onToggleBrowser?() } }
        case let .fxKnob(u, k, v):
            // D/W + Regler 1–3: Gruppe = Stärke der Slots, Single = Parameter des Effekts
            guard let fu = fxUnit(unit, section: u) else { return }
            core.updateFX(fu) { fx in
                if k == 0 { fx.dryWet = v } else if fx.single { fx.params[k - 1] = v } else { fx.slots[k - 1].amount = v }
            }
        case let .fxButton(u, b, down):
            guard down, let fu = fxUnit(unit, section: u) else { return }
            core.updateFX(fu) { fx in
                if fx.single {
                    // Single: Taste 1 = an/aus, Mode = nächster Effekt
                    if b == 0 { fx.singleType = (fx.singleType + 1) % FXUnitState.Effect.allCases.count }
                    else if b == 1 { fx.singleOn.toggle() }
                    return
                }
                if b == 0 {
                    // Mode-Taste: alle Slots aus, sonst Delay-Zeit weiterschalten
                    if fx.anyOn { for i in fx.slots.indices { fx.slots[i].on = false } }
                    else { fx.delayIndex = (fx.delayIndex + 1) % MixEngine.delayBeats.count }
                } else {
                    fx.slots[b - 1].on.toggle()
                }
            }
        case let .fxAssign(s, u, down):
            if down, let fu = fxUnit(unit, section: u) { core.toggleFXAssign(deck(s), fu) }
        case let .strip(s, pos, touching):
            let d = deck(s)
            if !touching { core.bend(d, 0); unit.stripLast[s] = nil; return }
            let seek = (p.stripMode == .seek) != unit.shift
            if seek {
                core.seek(d, fraction: pos)
            } else if let last = unit.stripLast[s] {
                core.bend(d, max(-6, min(6, (pos - last) * 300 * p.stripSensitivity)))
            }
            unit.stripLast[s] = pos
        case .shift:
            break
        }
    }
}

/// Ein einzelnes X1 MK2: dekodiert Reports, merkt Zustände, schreibt LEDs.
final class X1Unit {
    enum Side: Hashable { case left, right }
    enum Event {
        case play(Side, Bool), cue(Side, Bool), sync(Side, Bool), flux(Side, Bool), hotcue(Side, Int, Bool)
        case loopTurn(Side, Int), loopPush(Side, Bool), load(Side, Bool)
        case browseTurn(Int), browsePush(Bool), shift(Bool)
        case fxKnob(Int, Int, Double), fxButton(Int, Int, Bool), fxAssign(Side, Int, Bool)
        case strip(Side, Double, Bool)
    }

    let device: IOHIDDevice
    var info: X1Status.Info
    weak var manager: X1Manager?
    var shift = false
    var fluxHeld: [Side: Bool] = [:]
    var fluxComboUsed: [Side: Bool] = [:]
    var syncHeld: [Side: Bool] = [:]
    var syncComboUsed: [Side: Bool] = [:]
    var cueAsNormal: [Side: Bool] = [:]
    var stripLast: [Side: Double] = [:]
    var flashUntil: Date?
    private var prev = [UInt8](repeating: 0, count: 32)
    private var havePrev = false
    private var lastLED: [UInt8] = []
    private var lastDisplay: [UInt8] = []

    init(device: IOHIDDevice, info: X1Status.Info, manager: X1Manager) {
        self.device = device
        self.info = info
        self.manager = manager
    }

    // Tasten: (Byte, Bit, Ereignis-Erzeuger)
    private lazy var buttons: [(Int, UInt8, (Bool) -> Event)] = [
        (0x16, 0x01, { .play(.left, $0) }), (0x16, 0x02, { .cue(.left, $0) }),
        (0x16, 0x04, { .sync(.left, $0) }), (0x16, 0x08, { .flux(.left, $0) }),
        (0x16, 0x80, { .hotcue(.left, 0, $0) }), (0x16, 0x40, { .hotcue(.left, 1, $0) }),
        (0x16, 0x20, { .hotcue(.left, 2, $0) }), (0x16, 0x10, { .hotcue(.left, 3, $0) }),
        (0x15, 0x01, { .play(.right, $0) }), (0x15, 0x02, { .cue(.right, $0) }),
        (0x15, 0x04, { .sync(.right, $0) }), (0x15, 0x08, { .flux(.right, $0) }),
        (0x15, 0x80, { .hotcue(.right, 0, $0) }), (0x15, 0x40, { .hotcue(.right, 1, $0) }),
        (0x15, 0x20, { .hotcue(.right, 2, $0) }), (0x15, 0x10, { .hotcue(.right, 3, $0) }),
        (0x14, 0x08, { .load(.left, $0) }), (0x14, 0x02, { .load(.right, $0) }),
        (0x17, 0x01, { .loopPush(.left, $0) }), (0x14, 0x01, { .loopPush(.right, $0) }),
        (0x17, 0x02, { .browsePush($0) }),
        (0x13, 0x80, { .fxButton(0, 0, $0) }), (0x13, 0x40, { .fxButton(0, 1, $0) }),
        (0x13, 0x20, { .fxButton(0, 2, $0) }), (0x13, 0x10, { .fxButton(0, 3, $0) }),
        (0x13, 0x08, { .fxButton(1, 0, $0) }), (0x13, 0x04, { .fxButton(1, 1, $0) }),
        (0x13, 0x02, { .fxButton(1, 2, $0) }), (0x13, 0x01, { .fxButton(1, 3, $0) }),
        (0x14, 0x80, { .fxAssign(.left, 0, $0) }), (0x14, 0x40, { .fxAssign(.left, 1, $0) }),
        (0x14, 0x20, { .fxAssign(.right, 0, $0) }), (0x14, 0x10, { .fxAssign(.right, 1, $0) }),
    ]

    func parse(_ r: [UInt8]) {
        guard r.count >= 0x1F, r[0] == 0x01 else { return }
        defer { prev = Array(r.prefix(32)); havePrev = true }
        guard havePrev else { return }
        // Shift zuerst, damit Kombinationen im selben Report stimmen
        if (r[0x14] ^ prev[0x14]) & 0x04 != 0 {
            shift = r[0x14] & 0x04 != 0
            manager?.handle(.shift(shift), unit: self)
        }
        for (byte, bit, make) in buttons where (r[byte] ^ prev[byte]) & bit != 0 {
            manager?.handle(make(r[byte] & bit != 0), unit: self)
        }
        // Encoder: 4-Bit-Zähler
        func delta(_ new: UInt8, _ old: UInt8) -> Int {
            let d = (Int(new) - Int(old) + 16) % 16
            return d == 0 ? 0 : (d < 8 ? 1 : -1)
        }
        let browse = delta(r[0x11] >> 4, prev[0x11] >> 4)
        if browse != 0 { manager?.handle(.browseTurn(browse), unit: self) }
        let l = delta(r[0x11] & 0x0F, prev[0x11] & 0x0F)
        if l != 0 { manager?.handle(.loopTurn(.left, l), unit: self) }
        let rr = delta(r[0x12] & 0x0F, prev[0x12] & 0x0F)
        if rr != 0 { manager?.handle(.loopTurn(.right, rr), unit: self) }
        // FX-Regler (12 Bit, little endian): Unit 1 ab 0x01, Unit 2 ab 0x09
        for u in 0..<2 {
            for k in 0..<4 {
                let o = 0x01 + u * 8 + k * 2
                let v = Int(r[o]) | (Int(r[o + 1]) << 8)
                let pv = Int(prev[o]) | (Int(prev[o + 1]) << 8)
                if abs(v - pv) > 8 { manager?.handle(.fxKnob(u, k, Double(v & 0x0FFF) / 4095), unit: self) }
            }
        }
        // Touchstrip: Position 0–2047; links = linke Seite, rechts = rechte Seite
        let pos = Int(r[0x1B]) | (Int(r[0x1C] & 0x07) << 8)
        let ppos = Int(prev[0x1B]) | (Int(prev[0x1C] & 0x07) << 8)
        if pos != ppos {
            let touching = pos > 0
            let p = touching ? pos : ppos
            let side: Side = p < 1024 ? .left : .right
            let frac = side == .left ? Double(p) / 1023 : Double(p - 1024) / 1023
            manager?.handle(.strip(side, max(0, min(1, frac)), touching), unit: self)
        }
    }

    // MARK: - LEDs

    func sendLEDs(state: MixState, prefs: X1Prefs) {
        let on = UInt8(max(0, min(127, prefs.ledOn))), dim = UInt8(max(0, min(127, prefs.ledOff)))
        var r = [UInt8](repeating: 0, count: 0x34)
        r[0] = 0x80
        let flash = flashUntil.map { $0 > Date() } ?? false
        func scale(_ c: (r: UInt8, g: UInt8, b: UInt8)) -> (UInt8, UInt8, UInt8) {
            (UInt8(Int(c.r) * Int(on) / 127), UInt8(Int(c.g) * Int(on) / 127), UInt8(Int(c.b) * Int(on) / 127))
        }
        for (s, d) in [(Side.left, info.left), (Side.right, info.right)] {
            let deck = state.decks[d]
            let left = s == .left
            r[left ? 0x31 : 0x33] = deck.playing ? on : dim
            r[left ? 0x30 : 0x32] = deck.reverse || deck.cueHeld ? on : dim
            r[left ? 0x2D : 0x2F] = deck.sync ? on : dim
            r[left ? 0x2C : 0x2E] = deck.flux || fluxHeld[s] == true ? on : dim
            r[left ? 0x11 : 0x13] = deck.track != nil ? on : dim
            let f0 = manager?.fxUnit(self, section: 0), f1 = manager?.fxUnit(self, section: 1)
            r[left ? 0x09 : 0x0F] = f0.map { deck.fxAssign[$0] } == true ? on : dim
            r[left ? 0x0A : 0x10] = f1.map { deck.fxAssign[$0] } == true ? on : dim
            let pads = left ? [0x14, 0x17, 0x20, 0x23] : [0x1A, 0x1D, 0x26, 0x29]
            for (n, base) in pads.enumerated() {
                var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                if flash {
                    c = (on, on, on)
                } else if fluxHeld[s] == true || syncHeld[s] == true, n >= 2 {
                    c = (on / 2, on / 2, on / 2)               // Beatjump-Ebene sichtbar machen
                } else if let cue = deck.hotcues[n] {
                    let start = deck.track.flatMap { t in t.cues.first { $0.kind == .load }?.startMs ?? t.gridAnchorMs }
                    c = scale(prefs.color(for: cue, startMs: start, bpm: deck.grid?.bpm ?? deck.track?.bpm ?? 0).rgb)
                }
                r[base] = c.0; r[base + 1] = c.1; r[base + 2] = c.2
            }
        }
        r[0x12] = shift ? on : dim
        for u in 0..<2 {
            guard let fu = manager?.fxUnit(self, section: u) else { continue }
            let fx = state.fx[fu]
            r[0x01 + u * 4] = fx.anyOn ? on : dim
            for i in 0..<3 { r[0x02 + u * 4 + i] = (fx.single ? i == 0 && fx.singleOn : fx.slots[i].on) ? on : dim }
        }
        if r != lastLED {
            lastLED = r
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, r, r.count)
        }
        sendDisplay(state: state)
    }

    /// 7-Segment-Anzeigen: Loopgröße der jeweiligen Seite (wie Traktor)
    private func sendDisplay(state: MixState) {
        var r = [UInt8](repeating: 0, count: 0x5B)
        r[0] = 0x81
        for (i, d) in [info.left, info.right].enumerated() {
            let size = state.decks[d].loopSize
            let text = size >= 1 ? String(Int(size)) : String(Int((1 / size).rounded()))
            let chars = Array(String(repeating: " ", count: max(0, 3 - text.count)) + text).suffix(3)
            for (pos, ch) in chars.enumerated() {
                for seg in Self.segments[ch] ?? [] { r[0x01 + i * 0x18 + pos * 8 + seg] = 0x7f }
            }
            // Punkt vor der Zahl = Bruchteil (1/x)
            if size < 1 { r[0x01 + i * 0x18 + (3 - text.count) * 8] = 0x7f }
        }
        if r != lastDisplay {
            lastDisplay = r
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x81, r, r.count)
        }
    }

    private static let segments: [Character: [Int]] = [
        "0": [2, 3, 4, 5, 6, 7], "1": [2, 3], "2": [1, 3, 4, 6, 7], "3": [1, 2, 3, 4, 7], "4": [1, 2, 3, 5],
        "5": [4, 5, 1, 2, 7], "6": [4, 5, 1, 2, 6, 7], "7": [4, 3, 2], "8": [1, 2, 3, 4, 5, 6, 7], "9": [5, 4, 1, 3, 2, 7],
        "-": [1], " ": [],
    ]
}
