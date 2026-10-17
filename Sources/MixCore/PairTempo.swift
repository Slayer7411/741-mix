import Foundation

/// Zwei-Mac-Takt: welcher Mac führt Link. Beide Macs rechnen mit denselben Eingaben und kommen zum selben Ergebnis.
public enum PairTempo {
    /// Führung nach dem Stand beider Macs. Spielt das Master-Deck nur auf einer Seite, führt diese Seite; sonst bleibt
    /// die bisherige Führung. Widersprechen sich die Stände (beide oder keiner führt), führt der kleinere Name.
    public static func leads(ownPlaying: Bool, peerPlaying: Bool, ownLeads: Bool, peerLeads: Bool,
                             ownName: String, peerName: String) -> Bool {
        if ownPlaying != peerPlaying { return ownPlaying }
        if ownLeads != peerLeads { return ownLeads }
        return ownName < peerName
    }
}
