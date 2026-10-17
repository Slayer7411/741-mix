import Foundation
import Network
import SystemConfiguration
import MixCore
import MixEngine

/// Zwei Macs als eine Session: beide bieten sich per Bonjour an (`_minos741._tcp`, jede Verbindung: Ethernet,
/// Thunderbolt-/USB-Bridge, WLAN) und suchen sich gegenseitig; der Mac mit dem kleineren Namen verbindet sich (eine
/// Verbindung, unabhängig davon, wer schreibt – sonst warteten zwei schreibende Macs still). Jeder Mac spielt seine Decks (⌘, -> DECKS)
/// über sein eigenes Interface, den Takt hält Link. Über die Verbindung laufen die Gespielt-Markierungen; in die
/// Collection schreibt nur der schreibende Mac. Umschalten wirkt sofort
@MainActor
final class PairLink {
    static let shared = PairLink()
    static let service = "_minos741._tcp"

    private let queue = DispatchQueue(label: "minos741.pair", qos: .utility)
    private(set) var setup = PairSetup()
    private weak var history: HistoryStore?
    private weak var mix: MixModel?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var reader = PairLineReader()
    /// Stand des anderen Macs (nach hello / state)
    private(set) var peer: (name: String, writes: Bool, decks: [Int])?
    /// LIVE-Schalter (nicht gespeichert): kein Ruhezustand
    @ObservationIgnored var onLive: ((Bool) -> Void)?

    /// Einstellung übernehmen. An/aus baut die Verbindung auf oder ab; Schreiber und Decks gehen über die bestehende
    /// Verbindung an den anderen Mac (kein Neuaufbau)
    func configure(_ new: PairSetup, history: HistoryStore, mix: MixModel) {
        guard !Session.isSelfTest, new != setup else { return }
        if new.on, setup.on {
            setup = new
            send(.state(writes: new.writes, decks: new.decks))
            report()
            return
        }
        peer = nil
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let old = connection
        connection = nil
        old?.cancel()
        setup = new
        self.history = history
        self.mix = mix
        guard new.on else {
            history.onPlayedChange = nil
            StatusCenter.post(.info, String(localized: "Zwei-Mac: aus"), key: "pair")
            return
        }
        history.onPlayedChange = { add, remove in
            PairLink.shared.send(.played(add: add.sorted(), remove: remove.sorted()))
        }
        listen()
        browse()
    }

    private static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "MINOS-741"
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        return NWParameters(tls: nil, tcp: tcp)
    }

    nonisolated private static func main(_ f: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(f) }
    }

    // MARK: Verbinden

    private func listen() {
        do {
            let l = try NWListener(using: Self.parameters())
            l.service = NWListener.Service(name: Self.computerName, type: Self.service)
            l.newConnectionHandler = { c in Self.main { PairLink.shared.adopt(c) } }
            l.stateUpdateHandler = { s in
                if case .failed = s { Self.main { if PairLink.shared.listener === l { PairLink.shared.restartListener() } } }
            }
            l.start(queue: queue)
            listener = l
            StatusCenter.post(.info, String(localized: "Zwei-Mac: sucht den zweiten Mac"), key: "pair")
        } catch {
            StatusCenter.post(.error, String(localized: "Zwei-Mac: kein Netz-Dienst (\(error.localizedDescription))"), key: "pair")
        }
    }

    private func restartListener() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { let p = PairLink.shared; if p.setup.on, p.listener == nil { p.listen() } }
        }
    }

    private func browse() {
        browser?.cancel()
        let b = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: Self.parameters())
        let own = Self.computerName
        b.browseResultsChangedHandler = { results, _ in
            // der andere Mac; verbinden nur, wenn der eigene Name kleiner ist (der andere nimmt an)
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint, Self.initiates(own: own, peer: name) else { continue }
                let ep = r.endpoint
                Self.main { PairLink.shared.found(ep) }
                break
            }
        }
        b.start(queue: queue)
        browser = b
    }

    /// wer die Verbindung aufbaut: nicht man selbst, der kleinere Name
    nonisolated static func initiates(own: String, peer: String) -> Bool { peer != own && own < peer }

    private func found(_ ep: NWEndpoint) {
        guard setup.on, connection == nil else { return }
        adopt(NWConnection(to: ep, using: Self.parameters()))
    }

    /// genau ein Gegenüber: eine neue Verbindung ersetzt die alte
    private func adopt(_ c: NWConnection) {
        connection?.cancel()
        connection = c
        reader = PairLineReader()
        c.stateUpdateHandler = { s in Self.main { PairLink.shared.changed(s, of: c) } }
        c.start(queue: queue)
        receive(c)
    }

    private func changed(_ s: NWConnection.State, of c: NWConnection) {
        guard c === connection else { return }
        switch s {
        case .ready:
            send(.hello(writes: setup.writes, decks: setup.decks, version: PairMessage.version, name: Self.computerName,
                        played: (history?.played ?? []).sorted()))
            if let mix, !mix.clock.linkEnabled { mix.toggleLink() }
        case .failed, .waiting:
            c.cancel()
        case .cancelled:
            connection = nil
            peer = nil
            StatusCenter.post(.warning, String(localized: "Zwei-Mac: Verbindung getrennt"), key: "pair")
            // neu suchen (die Trefferliste meldet nur Änderungen)
            if setup.on {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    MainActor.assumeIsolated { let p = PairLink.shared; if p.setup.on, p.connection == nil { p.browse() } }
                }
            }
        default:
            break
        }
    }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, error in
            Self.main {
                let link = PairLink.shared
                guard c === link.connection else { return }
                if let data { link.reader.feed(data).forEach(link.handle) }
                if done || error != nil { c.cancel() } else { link.receive(c) }
            }
        }
    }

    // MARK: Nachrichten

    private func send(_ m: PairMessage) {
        guard let c = connection, c.state == .ready else { return }
        c.send(content: m.line(), completion: .contentProcessed { _ in })
    }

    private func handle(_ m: PairMessage) {
        guard let history else { return }
        switch m {
        case let .hello(writes, decks, version, name, played):
            peer = (name, writes, decks)
            if version != PairMessage.version {
                StatusCenter.post(.error, String(localized: "Zwei-Mac: \(name) hat eine andere Version – beide Macs auf denselben Stand bringen"), key: "pair")
            }
            // beide schreiben: der Mac mit dem größeren Namen gibt ab (danach Schalter oben)
            if writes, setup.writes, Self.computerName > name { mix?.prefs.ui.pair.writes = false }
            report()
            if setup.writes {
                let s = PairPlayed.merged(history.played, Set(played))
                history.applyPlayed(s)
                send(.playedSet(s.sorted()))
            }
            if let mix, mix.live { send(.live(true)) }
        case let .state(writes, decks):
            guard let p = peer else { return }
            peer = (p.name, writes, decks)
            // der andere hat das Schreiben übernommen -> abgeben
            if writes, setup.writes { mix?.prefs.ui.pair.writes = false }
            report()
        case let .live(on):
            if let mix, mix.live != on { mix.setLive(on, fromPeer: true) }
        case let .playedSet(s):
            if !setup.writes { history.applyPlayed(Set(s)) }
        case let .played(add, remove):
            history.applyPlayed(history.played.subtracting(remove).union(add))
        }
    }

    /// Statusleiste: verbunden mit wem, wer schreibt, Probleme
    private func report() {
        guard let p = peer else { return }
        let problems = PairCheck.problems(ownWrites: setup.writes, ownDecks: setup.decks, peerWrites: p.writes, peerDecks: p.decks)
        let theirs = p.decks.map { deckLetters[$0] }.joined(separator: "/")
        var text = String(localized: "Zwei-Mac: verbunden mit \(p.name) (Decks \(theirs))") + " · "
            + (setup.writes ? String(localized: "dieser Mac schreibt") : p.writes ? String(localized: "\(p.name) schreibt") : "")
        for q in problems {
            switch q {
            case .bothWrite: text += String(localized: "beide schreiben")
            case .noneWrites: text += String(localized: "kein Mac schreibt – Schalter SCHREIBT oben")
            case let .sharedDecks(d): text += " · " + String(localized: "Deck \(d.map { deckLetters[$0] }.joined(separator: "/")) auf beiden")
            }
        }
        StatusCenter.post(problems.isEmpty ? .ok : .warning, text, key: "pair")
    }

    var connected: Bool { peer != nil }

    /// LIVE an/aus an den anderen Mac
    func sendLive(_ on: Bool) { send(.live(on)) }
}
