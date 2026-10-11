// Dekodieren, Analyse, Übersicht, Cover liegen in MixMedia (auch für den Datei-Dienst); App und Tests sehen sie weiter über MixEngine
@_exported import MixMedia

extension DeckState {
    /// offener Phrasen-Vorschlag in ganzen Beats relativ zum jetzigen Anker (nil = keiner / schon übernommen)
    public var phraseSuggestion: Int? {
        guard let t = phraseTarget, let g = grid, g.bpm > 0 else { return nil }
        let n = Int(((t - g.anchor) / g.beat).rounded())
        return n == 0 ? nil : n
    }
}
