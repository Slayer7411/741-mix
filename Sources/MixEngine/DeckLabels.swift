/// Buchstaben der Decks 0…3, einmal beim Start gesetzt. Zwei-Mac-Modus: Mac 1 zeigt seine Decks als A/C, Mac 2 als B/D
public enum DeckLabels {
    nonisolated(unsafe) public static var letters = ["A", "B", "C", "D"]
    public static let leader = ["A", "C", "B", "D"]
    public static let follower = ["B", "D", "A", "C"]
}
