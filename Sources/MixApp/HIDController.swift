import Foundation
import AppKit
import IOKit.hid
import Observation
import MixCore
import MixEngine

/// Anzeige-Seite für die Einstellungen (Hauptthread)
@MainActor @Observable
final class ControllerStatus {
    struct Info: Identifiable, Hashable {
        let id: String          // Seriennummer
        let location: Int
        var left: Int           // Deck-Index der linken Seite
        var right: Int
        /// welcher Browser-Bereich: 0 = links/oben, 1 = rechts/unten
        var pane: Int = 0
        /// FX-Sektionen: -1 = FX1/FX2, 0 = beide FX1, 1 = beide FX2, 10 = FX1/FX3, 11 = FX2/FX4
        var fxUnit: Int = -1
        /// Produktname, Seriennummer ("" = keine) und feste Seite (nil = dritter Controller)
        var name = ""
        var serial = ""
        var side: ControllerSide?
    }
    var devices: [Info] = []
    var lastEvent = ""
    @ObservationIgnored weak var manager: ControllerManager?

    func assign(_ serial: String, left: Int, right: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].left = left
        devices[i].right = right
        E2E.defaults.set([left, right], forKey: "x1.\(serial)")
        manager?.assign(serial, left: left, right: right)
    }

    func assignPane(_ serial: String, _ pane: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].pane = pane
        E2E.defaults.set(pane, forKey: "x1pane.\(serial)")
        manager?.assignPane(serial, pane)
    }

    func assignFX(_ serial: String, _ unit: Int) {
        guard let i = devices.firstIndex(where: { $0.id == serial }) else { return }
        devices[i].fxUnit = unit
        E2E.defaults.set(unit, forKey: "x1fx.\(serial)")
        manager?.assignFX(serial, unit)
    }

    func identify(_ serial: String) { manager?.identify(serial) }

    /// Seite wechseln (Decks, Browser, FX folgen); ein anderer Controller auf dieser Seite tauscht
    func setSide(_ id: String, _ side: ControllerSide) { manager?.setSide(id, side) }

    func playShow(_ id: String) { manager?.playShow(id) }

    /// Infos aus der Steuer-Queue übernehmen
    func update(_ infos: [Info]) {
        for i in infos {
            if let k = devices.firstIndex(where: { $0.id == i.id }) { devices[k] = i }
        }
    }
}

/// DJ-Controller (2 Deck-Seiten, 2 FX-Sektionen, Browse-Encoder, Touchstrip) im nativen HID-Modus (VID 0x17cc, PID 0x1220).
/// Läuft komplett auf der Steuer-Queue des Kerns – unabhängig von der Oberfläche.
/// Protokoll: Input-Report 0x01 (Tasten/Regler), Output 0x80 (Tasten-LEDs, RGB-Pads), 0x81 (7-Segment, Touchstrip).
/// Byte-Positionen aus einem öffentlichen HID-Mapping; Standardbelegung plus Christians eigene Zuordnungen, alles in den Einstellungen änderbar.
final class ControllerManager: @unchecked Sendable {
    let core: MixController
    let status: ControllerStatus
    private var manager: IOHIDManager?
    fileprivate var units: [String: ControllerUnit] = [:]
    private let lock = NSLock()
    private var _prefs = ControllerPrefs()
    /// 2 oder 4 FX-Units (aus den Einstellungen)
    var fxUnits = 2
    // gebündelte Browse-Schritte (nur auf der Steuer-Queue anfassen)
    private var pendingBrowse: [Int: Int] = [:]
    private var browseScheduled = false
    /// Browser-Aktionen (laufen auf dem Hauptthread)
    /// Browser-Aktionen je Bereich (pane), laufen auf dem Hauptthread
    var onBrowse: (@MainActor (_ pane: Int, _ step: Int) -> Void)?
    /// force: Shift + LOAD übergeht den Lade-Schutz
    var onLoad: (@MainActor (_ pane: Int, _ deck: Int, _ force: Bool) -> Void)?
    var onPreview: (@MainActor (_ pane: Int) -> Void)?
    var onToggleBrowser: (@MainActor () -> Void)?
    var onMatching: (@MainActor (_ pane: Int) -> Void)?
    /// Seite eines Geräts speichern (ControllerPrefs.sides, Hauptthread)
    var onSide: (@MainActor (_ key: String, _ side: ControllerSide) -> Void)?
    /// in dieser Sitzung gespeicherte Seiten (Steuer-Queue), gehen vor prefs.sides, bis die Einstellungen nachziehen
    private var localSides: [String: ControllerSide] = [:]

    /// Standard: erster Controller (nach USB-Position) steuert A/C, der zweite B/D – pro Gerät in den Einstellungen änderbar.
    static let defaultAssignments: [(Int, Int)] = [(0, 2), (1, 3), (0, 1), (2, 3)]

    var prefs: ControllerPrefs {
        get { lock.lock(); defer { lock.unlock() }; return _prefs }
        set { lock.lock(); _prefs = newValue; lock.unlock() }
    }

    @MainActor init(core: MixController, status: ControllerStatus) {
        self.core = core
        self.status = status
        status.manager = self
    }

    func start() {
        open()
        core.addTickHandler { [weak self] c in self?.refreshLEDs(c) }
        // nach dem Ruhezustand alle Controller neu verbinden (USB-Geräte kommen mit neuer Verbindung zurück)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: nil) { [weak self] _ in
            guard let self else { return }
            self.core.controlQueue.async { self.reopen() }
        }
        // MIX741_LEDSHOW=1: Startsequenz nach dem Start noch einmal (Vorführen), nur mit verbundenen Controllern
        if ProcessInfo.processInfo.environment["MIX741_LEDSHOW"] == "1" {
            core.controlQueue.asyncAfter(deadline: .now() + 6) {
                print("[hid] MIX741_LEDSHOW: \(self.units.count) Controller")
                for u in self.units.values { u.startShow() }
            }
        }
    }
    private var wakeObserver: NSObjectProtocol?

    /// Manager schließen, Geräte vergessen, neu öffnen (Steuer-Queue): Matching meldet alle angeschlossenen neu
    private func reopen() {
        if let m = manager {
            IOHIDManagerCancel(m)
            IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        manager = nil
        units.removeAll()
        DispatchQueue.main.async { self.status.devices.removeAll() }
        print("[hid] nach dem Aufwachen neu verbinden")
        open()
    }

    private func open() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x17cc, kIOHIDProductIDKey: 0x1220] as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, _, _, device in
            Unmanaged<ControllerManager>.fromOpaque(ctx!).takeUnretainedValue().attach(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            Unmanaged<ControllerManager>.fromOpaque(ctx!).takeUnretainedValue().detach(device)
        }, ctx)
        // Reports zentral über den Manager (pro Gerät ist das nach Activate nicht erlaubt)
        IOHIDManagerRegisterInputReportCallback(m, { ctx, _, sender, _, _, report, len in
            let me = Unmanaged<ControllerManager>.fromOpaque(ctx!).takeUnretainedValue()
            guard let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            me.units.values.first { $0.device == device }?.parse(Array(UnsafeBufferPointer(start: report, count: len)))
        }, ctx)
        // HID-Ereignisse direkt auf der Steuer-Queue, nicht auf dem Hauptthread
        IOHIDManagerSetDispatchQueue(m, core.controlQueue)
        // ohne Open kommen keine Input-Reports an
        let st = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        print("[hid] HID-Manager geöffnet: \(st)")
        IOHIDManagerActivate(m)
        manager = m
    }

    private func attach(_ device: IOHIDDevice) {
        func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(device, k as CFString) }
        register(device: device, serial: prop(kIOHIDSerialNumberKey) as? String ?? "", location: prop(kIOHIDLocationIDKey) as? Int ?? 0,
                 name: prop(kIOHIDProductKey) as? String ?? "Controller")
    }

    /// Gerät aufnehmen (Steuer-Queue; device nil = Tests): Seite bestimmen, speichern, Startsequenz
    @discardableResult
    func register(device: IOHIDDevice?, serial rawSerial: String, location loc: Int, name: String) -> ControllerStatus.Info? {
        let serial = rawSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = ControllerSides.key(serial: serial, location: loc) ?? ControllerSides.tempPrefix + UUID().uuidString
        guard units[key] == nil else { return nil }
        let d = E2E.defaults
        let saved = d.array(forKey: "x1.\(key)") as? [Int]
        let savedPane = d.object(forKey: "x1pane.\(key)") as? Int
        let savedFX = d.object(forKey: "x1fx.\(key)") as? Int
        var info: ControllerStatus.Info
        let stable = ControllerSides.isStable(key)
        let stored = stable ? storedSide(key) : nil
        // ohne gespeicherte Seite: alte Deck-Zuordnung A/C bzw. B/D übernehmen
        let wanted = stored ?? saved.flatMap { $0.count == 2 ? ControllerSide(decks: $0[0], $0[1]) : nil }
        if let (side, moved) = ControllerSides.resolve(saved: wanted, taken: Set(units.values.compactMap(\.info.side))) {
            // eigene Zuordnung (Decks, Browser, FX) gilt nur, wenn das Gerät seine Seite bekommt
            if moved { clearOverrides(key) }
            let decks = !moved ? saved.flatMap { $0.count == 2 ? ($0[0], $0[1]) : nil } ?? side.decks : side.decks
            info = .init(id: key, location: loc, left: decks.0, right: decks.1, pane: !moved ? savedPane ?? side.pane : side.pane)
            info.fxUnit = !moved ? savedFX ?? side.fxUnit : side.fxUnit
            info.side = side
            if stable, stored != side { storeSide(key, side) }
        } else {
            // dritter Controller: der Reihe nach wie bisher
            let def = Self.defaultAssignments[min(units.count, Self.defaultAssignments.count - 1)]
            info = .init(id: key, location: loc, left: saved?.first ?? def.0, right: saved?.last ?? def.1,
                         pane: savedPane ?? min(units.count, 1))
            info.fxUnit = savedFX ?? ([0, 2].contains(info.left) || [0, 2].contains(info.right) ? 10 : 11)
        }
        info.name = name
        info.serial = serial
        let unit = ControllerUnit(device: device, info: info, manager: self)
        units[key] = unit
        if prefs.startShow { unit.startShow() }
        print("[hid] Controller \(key) verbunden: \(info.side?.rawValue ?? "-") \(deckLetters[info.left]) / \(deckLetters[info.right])")
        let final = info
        DispatchQueue.main.async {
            self.status.devices.append(final)
            self.status.devices.sort { ($0.side?.rawValue ?? "z", $0.location) < ($1.side?.rawValue ?? "z", $1.location) }
            self.status.lastEvent = "Controller \(key) verbunden"
        }
        announce(info)
        return info
    }

    /// gespeicherte Seite eines Geräts (Steuer-Queue)
    func storedSide(_ key: String) -> ControllerSide? { localSides[key] ?? ControllerSides.saved(key, in: prefs.sides) }

    func unit(_ key: String) -> ControllerUnit? { units[key] }

    /// Statusleiste: welche Decks der Controller steuert
    private func announce(_ i: ControllerStatus.Info) {
        let a = deckLetters[i.left], b = deckLetters[i.right]
        let text = switch i.side {
        case .left: String(localized: "Controller links: \(a) / \(b)")
        case .right: String(localized: "Controller rechts: \(a) / \(b)")
        case nil: String(localized: "Controller: \(a) / \(b)")
        }
        StatusCenter.post(.info, text, key: "controller.\(i.id)")
    }

    private func storeSide(_ key: String, _ side: ControllerSide) {
        localSides[key] = side
        DispatchQueue.main.async { self.onSide?(key, side) }
    }

    /// eigene Deck-/Browser-/FX-Zuordnung eines Geräts verwerfen (Seite bestimmt sie wieder)
    private func clearOverrides(_ key: String) {
        for k in ["x1.", "x1pane.", "x1fx."] { E2E.defaults.removeObject(forKey: k + key) }
    }

    /// Seite wechseln (Steuer-Queue): Decks, Browser und FX folgen der Seite, ein anderes Gerät auf ihr tauscht
    func setSide(_ key: String, _ side: ControllerSide) {
        core.controlQueue.async {
            guard self.units[key] != nil else { return }
            let current = self.units.compactMapValues(\.info.side)
            let next = ControllerSides.assign(key, to: side, current: current)
            var changed: [ControllerStatus.Info] = []
            for (k, s) in next where current[k] != s || k == key {
                guard let u = self.units[k] else { continue }
                self.clearOverrides(k)
                u.info.side = s
                (u.info.left, u.info.right) = s.decks
                u.info.pane = s.pane
                u.info.fxUnit = s.fxUnit
                u.resetLEDs()
                if ControllerSides.isStable(k) { self.storeSide(k, s) }
                // Decks der neuen Seite zeigen (ohne Sturm, mitten im Einpendeln)
                if self.prefs.startShow { u.startShow(at: LEDShow.sideAt) }
                changed.append(u.info)
                self.announce(u.info)
            }
            DispatchQueue.main.async {
                self.status.update(changed)
                self.status.devices.sort { ($0.side?.rawValue ?? "z", $0.location) < ($1.side?.rawValue ?? "z", $1.location) }
            }
        }
    }

    func playShow(_ key: String) {
        core.controlQueue.async { self.units[key]?.startShow() }
    }

    private func detach(_ device: IOHIDDevice) {
        guard let (k, _) = units.first(where: { $0.value.device == device }) else { return }
        units[k] = nil
        DispatchQueue.main.async {
            self.status.devices.removeAll { $0.id == k }
            self.status.lastEvent = "Controller \(k) getrennt"
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

    // MARK: - Ereignisse von einem Controller (Steuer-Queue)

    /// welche FX-Unit eine Sektion (0 = links, 1 = rechts) dieses Controllers steuert
    func fxUnit(_ unit: ControllerUnit, section s: Int) -> Int? {
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

    func handle(_ e: ControllerUnit.Event, unit: ControllerUnit) {
        let p = prefs
        let deck: (ControllerUnit.Side) -> Int = { $0 == .left ? unit.info.left : unit.info.right }
        let text = "\(unit.info.id): " + String(describing: e).replacingOccurrences(of: "MixApp.ControllerUnit.Side.", with: "")
        DispatchQueue.main.async { self.status.lastEvent = text }
        if MixController.debug { print("[hid] \(text)"); fflush(stdout) }   // sonst ein write() je Reglerschritt auf der Steuer-Queue
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
            // Pad-Ebene: antippen = Hotcues 5–8 an/aus (bleibt); Flux-Modus: antippen = Flux-Modus. In beiden gehalten =
            // Pad-Ebene nur solange gedrückt. Shift + Flux nach Einstellung (Tap oder Flux-Modus)
            if down {
                if unit.shift {   // Shift + Flux: Tap (Grid einklopfen, wie die Werks-Belegung) oder Flux-Modus
                    switch p.shiftFlux {
                    case .tap: core.tapGrid(deck(s))
                    case .fluxMode: core.toggleFlux(deck(s))
                    }
                    return
                }
                unit.fluxHeld[s] = true
                unit.fluxComboUsed[s] = false
            } else if unit.fluxHeld[s] == true {
                if unit.fluxComboUsed[s] != true {
                    if p.fluxButton == .padLayer { unit.padLayer[s] = unit.padLayer[s] != true }
                    else if p.fluxTapToggles { core.toggleFlux(deck(s)) }
                }
                unit.fluxHeld[s] = false
            }
        case let .hotcue(s, n, down):
            guard down else { return }
            let d = deck(s)
            if unit.syncHeld[s] == true, n == 2 || n == 3 {
                // Sync gehalten hat Vorrang vor Flux und Pad-Ebene: immer genau ein Takt
                unit.syncComboUsed[s] = true
                if unit.fluxHeld[s] == true { unit.fluxComboUsed[s] = true }   // Flux loslassen schaltet dann keine Ebene
                core.stepJump(d, beats: n == 2 ? -1 : 1)   // ein Beat (ein Kick-Schlag), nicht ein Takt
            } else if unit.fluxHeld[s] == true {
                // Flux gehalten: Pads = Hotcues 5–8 (oder Beatjump auf Pad 3/4)
                unit.fluxComboUsed[s] = true
                if p.fluxPads == .hotcues { core.hotcue(d, n + 4, delete: unit.shift) }
                else if n == 2 || n == 3 { core.beatjump(d, beats: (n == 2 ? -1 : 1) * p.fluxBeatjumpBeats) }
            } else if unit.layerOn(s, p) {
                core.hotcue(d, n + 4, delete: unit.shift)   // Pad-Ebene eingerastet: Hotcues 5–8
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
            // Lade-Schutz hier prüfen (Steuer-Queue): ein spielendes Deck bekommt keinen Track, Shift + LOAD erzwingt
            guard down else { return }
            let d = deck(s), pane = unit.info.pane, force = unit.shift
            if force, p.shiftLoad == .double {   // Instant Double vom Deck der anderen Seite, Lade-Schutz gilt
                core.instantDouble(from: deck(s == .left ? .right : .left), to: d)
                return
            }
            if !force, core.loadBlocked(d) { return }
            DispatchQueue.main.async { self.onLoad?(pane, d, force) }
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
            // Drücken = Browser groß/klein bzw. Matching an/aus (⌘, -> CONTROLLER), Shift + Drücken = Vorhören
            guard down else { return }
            let pane = unit.info.pane
            if unit.shift { DispatchQueue.main.async { self.onPreview?(pane) } }
            else if p.browsePush == .matching { DispatchQueue.main.async { self.onMatching?(pane) } }
            else { DispatchQueue.main.async { self.onToggleBrowser?() } }
        case let .fxKnob(u, k, v):
            // D/W + Regler 1–3 = Schnellregler der Unit (FX-Belegung; Standard: Gruppe = Stärke je Slot, sonst Slot 1)
            guard let fu = fxUnit(unit, section: u) else { return }
            core.setFXControl(fu, k == 0 ? .dryWet : .knob(k - 1), v)
        case let .fxButton(u, b, down):
            guard down, let fu = fxUnit(unit, section: u) else { return }
            // Tasten 1–3 = Tasten der Unit (Standard: an/aus von Slot 1, Gruppe: an/aus je Slot)
            if b > 0 { core.pressFXButton(fu, b - 1); return }
            // Mode = alle Slots aus (gemerkt) bzw. wieder an, Shift + Mode = nächste Vorlage
            core.fxModeButton(fu, shift: unit.shift)
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

/// Ein einzelner Controller: dekodiert Reports, merkt Zustände, schreibt LEDs.
final class ControllerUnit {
    enum Side: Hashable { case left, right }
    enum Event: Equatable {
        case play(Side, Bool), cue(Side, Bool), sync(Side, Bool), flux(Side, Bool), hotcue(Side, Int, Bool)
        case loopTurn(Side, Int), loopPush(Side, Bool), load(Side, Bool)
        case browseTurn(Int), browsePush(Bool), shift(Bool)
        case fxKnob(Int, Int, Double), fxButton(Int, Int, Bool), fxAssign(Side, Int, Bool)
        case strip(Side, Double, Bool)
    }

    /// nil = ohne Gerät (Tests)
    let device: IOHIDDevice?
    var info: ControllerStatus.Info
    weak var manager: ControllerManager?
    var shift = false
    var fluxHeld: [Side: Bool] = [:]
    var fluxComboUsed: [Side: Bool] = [:]
    /// Flux-Taste als Schalter: Pads dieser Seite auf Hotcues 5–8
    var padLayer: [Side: Bool] = [:]
    var syncHeld: [Side: Bool] = [:]
    var syncComboUsed: [Side: Bool] = [:]
    var cueAsNormal: [Side: Bool] = [:]
    var stripLast: [Side: Double] = [:]
    var flashUntil: Date?
    private var prev = [UInt8](repeating: 0, count: 32)
    private var havePrev = false
    private var lastLED: [UInt8] = []
    private var lastDisplay: [UInt8] = []

    init(device: IOHIDDevice?, info: ControllerStatus.Info, manager: ControllerManager) {
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
        let events = decode(r)
        // echte Eingabe bricht die Startsequenz ab (Ereignis gilt normal)
        if !events.isEmpty, showStart != nil { stopShow() }
        for e in events { manager?.handle(e, unit: self) }
    }

    /// Report → Ereignisse in Reihenfolge (Shift zuerst); merkt sich den Report für den nächsten Vergleich
    func decode(_ r: [UInt8]) -> [Event] {
        guard r.count >= 0x1F, r[0] == 0x01 else { return [] }
        defer { prev = Array(r.prefix(32)); havePrev = true }
        guard havePrev else { return [] }
        var out: [Event] = []
        // Shift zuerst, damit Kombinationen im selben Report stimmen
        if (r[0x14] ^ prev[0x14]) & 0x04 != 0 {
            shift = r[0x14] & 0x04 != 0
            out.append(.shift(shift))
        }
        for (byte, bit, make) in buttons where (r[byte] ^ prev[byte]) & bit != 0 {
            out.append(make(r[byte] & bit != 0))
        }
        // Encoder: 4-Bit-Zähler
        func delta(_ new: UInt8, _ old: UInt8) -> Int {
            let d = (Int(new) - Int(old) + 16) % 16
            return d == 0 ? 0 : (d < 8 ? 1 : -1)
        }
        let browse = delta(r[0x11] >> 4, prev[0x11] >> 4)
        if browse != 0 { out.append(.browseTurn(browse)) }
        let l = delta(r[0x11] & 0x0F, prev[0x11] & 0x0F)
        if l != 0 { out.append(.loopTurn(.left, l)) }
        let rr = delta(r[0x12] & 0x0F, prev[0x12] & 0x0F)
        if rr != 0 { out.append(.loopTurn(.right, rr)) }
        // FX-Regler (12 Bit, little endian): Unit 1 ab 0x01, Unit 2 ab 0x09
        for u in 0..<2 {
            for k in 0..<4 {
                let o = 0x01 + u * 8 + k * 2
                let v = Int(r[o]) | (Int(r[o + 1]) << 8)
                let pv = Int(prev[o]) | (Int(prev[o + 1]) << 8)
                if abs(v - pv) > 8 { out.append(.fxKnob(u, k, Double(v & 0x0FFF) / 4095)) }
            }
        }
        // Touchstrip (erster Finger, 11 Bit): 0 = nicht berührt, 1…0x1C0 linke Hälfte (Deck A/C), 0x1C0…0x240 Totzone
        // in der Mitte, 0x240…0x400 rechte Hälfte (Deck B/D). Zweiter Finger liegt bei 0x1D, wird nicht genutzt
        let pos = Int(r[0x1B]) | (Int(r[0x1C] & 0x07) << 8)
        let ppos = Int(prev[0x1B]) | (Int(prev[0x1C] & 0x07) << 8)
        if pos != ppos, let e = Self.strip(pos, previous: ppos) { out.append(e) }
        return out
    }

    static let stripLeftMax = 0x1C0, stripRightMin = 0x240, stripMax = 0x400

    /// Strip-Wert → Ereignis (Seite, Anteil 0…1 von links nach rechts in der Hälfte, berührt); nil in der Totzone
    static func strip(_ pos: Int, previous: Int) -> Event? {
        let touching = pos > 0
        let p = touching ? pos : previous
        guard p > 0 else { return nil }
        if p <= stripLeftMax {
            return .strip(.left, max(0, min(1, Double(p - 1) / Double(stripLeftMax - 1))), touching)
        }
        if p >= stripRightMin {
            return .strip(.right, max(0, min(1, Double(p - stripRightMin) / Double(stripMax - stripRightMin))), touching)
        }
        return nil
    }

    /// Pad-Ebene 5–8 eingerastet (nur mit Flux-Taste = Pad-Ebene)
    func layerOn(_ s: Side, _ p: ControllerPrefs) -> Bool { p.fluxButton == .padLayer && padLayer[s] == true }

    // MARK: - LEDs

    // MARK: - Startsequenz (Steuer-Queue, im LED-Takt)

    /// Start der Sequenz (Systemlaufzeit), nil = normale LEDs
    private(set) var showStart: TimeInterval?
    private var showSeed: UInt32 = 0

    /// Sequenz starten, at = Einstieg in Sekunden (LEDShow.sideAt = Decks der Seite)
    func startShow(at offset: Double = 0) {
        showStart = ProcessInfo.processInfo.systemUptime - offset
        showSeed = UInt32.random(in: 0 ... .max)
    }

    func stopShow() {
        showStart = nil
        resetLEDs()
    }

    /// nächster LED-Takt schickt alles neu
    func resetLEDs() { lastLED = []; lastDisplay = [] }

    /// LED-Takt: Bild der laufenden Sequenz (LEDs im normalen Zustand übernehmen den normalen Report) oder normaler Zustand
    func sendLEDs(state: MixState, prefs: ControllerPrefs) {
        let on = UInt8(max(0, min(127, prefs.ledOn))), dim = UInt8(max(0, min(127, prefs.ledOff)))
        var show: LEDShow.Frame?
        if let start = showStart {
            show = LEDShow.frame(at: ProcessInfo.processInfo.systemUptime - start, decks: (info.left, info.right), seed: showSeed)
            if show == nil { stopShow() }
        }
        var led: [UInt8], disp: [UInt8]
        if let f = show {
            // normaler Zustand, im Atempuls kurz gedimmt
            let normal = (led: ledReport(state: state, prefs: prefs, on: LEDShow.breathPeak(on, f.breath), dim: dim),
                          display: displayReport(state: state))
            (led, disp) = LEDShow.reports(f, peak: on, normal: normal)
        } else {
            led = ledReport(state: state, prefs: prefs, on: on, dim: dim)
            disp = displayReport(state: state)
        }
        if led != lastLED, let device {
            lastLED = led
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x80, led, led.count)
        }
        if disp != lastDisplay, let device {
            lastDisplay = disp
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x81, disp, disp.count)
        }
    }

    /// normaler Zustand der Tasten- und Pad-LEDs (Report 0x80)
    private func ledReport(state: MixState, prefs: ControllerPrefs, on: UInt8, dim: UInt8) -> [UInt8] {
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
            // Pad-Ebene: Flux-LED zeigt die Ebene 5–8, Flux-Modus allein halb hell
            r[left ? 0x2C : 0x2E] = fluxHeld[s] == true || layerOn(s, prefs) || (deck.flux && prefs.fluxButton == .fluxMode) ? on
                : deck.flux ? max(dim, on / 3) : dim
            r[left ? 0x11 : 0x13] = deck.track != nil ? on : dim
            let f0 = manager?.fxUnit(self, section: 0), f1 = manager?.fxUnit(self, section: 1)
            r[left ? 0x09 : 0x0F] = f0.map { deck.fxAssign[$0] } == true ? on : dim
            r[left ? 0x0A : 0x10] = f1.map { deck.fxAssign[$0] } == true ? on : dim
            let pads = left ? [0x14, 0x17, 0x20, 0x23] : [0x1A, 0x1D, 0x26, 0x29]
            // Pads zeigen Hotcues 5–8: Flux gehalten (Pads = Hotcues) oder Ebene eingerastet
            let layer = fluxHeld[s] == true ? prefs.fluxPads == .hotcues : layerOn(s, prefs)
            for (n, base) in pads.enumerated() {
                var c: (UInt8, UInt8, UInt8) = (0, 0, 0)
                if flash {
                    c = (on, on, on)
                } else if (fluxHeld[s] == true && !layer) || syncHeld[s] == true, n >= 2 {
                    c = (on / 2, on / 2, on / 2)               // Sprung-Ebene sichtbar machen
                } else if let cue = deck.hotcues[layer ? n + 4 : n] {   // Ebene 5–8: zweite Hotcue-Reihe
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
            for i in 0..<3 { r[0x02 + u * 4 + i] = state.fxControls[fu][FXControl.button(i).slot].active ? on : dim }
        }
        return r
    }

    /// 7-Segment-Anzeigen: Loopgröße der jeweiligen Seite (Report 0x81)
    private func displayReport(state: MixState) -> [UInt8] {
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
        return r
    }

    /// Segmente je Zeichen (1 = g, 2 = c, 3 = b, 4 = a, 5 = f, 6 = e, 7 = d, 0 = Punkt)
    static let segments: [Character: [Int]] = [
        "0": [2, 3, 4, 5, 6, 7], "1": [2, 3], "2": [1, 3, 4, 6, 7], "3": [1, 2, 3, 4, 7], "4": [1, 2, 3, 5],
        "5": [4, 5, 1, 2, 7], "6": [4, 5, 1, 2, 6, 7], "7": [4, 3, 2], "8": [1, 2, 3, 4, 5, 6, 7], "9": [5, 4, 1, 3, 2, 7],
        "-": [1], " ": [], "A": [4, 3, 2, 6, 5, 1], "b": [2, 7, 6, 5, 1], "C": [4, 7, 6, 5], "d": [3, 2, 7, 6, 1],
    ]
}
