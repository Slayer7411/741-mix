import Foundation
import Testing
@testable import MixApp

// TIDAL ohne Netz: PKCE (RFC 7636), Anmelde-URL und Token-Antwort, Playlist-Name, Treffer-Prüfung, JSON:API-Formate

@Test func pkceChallengeMatchesRFC7636Vector() {
    // RFC 7636, Anhang B
    #expect(TidalPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func pkceVerifierIsUnpaddedBase64url() {
    let v = TidalPKCE.verifier()
    #expect(v.count == 43)
    #expect(v.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    #expect(v != TidalPKCE.verifier())
}

@Test func authorizeURLCarriesPKCEAndScopes() throws {
    let url = try #require(TidalAuth.authorizeURL(clientID: "abc", challenge: "xyz", state: "s1"))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func value(_ n: String) -> String? { items.first { $0.name == n }?.value }
    #expect(url.host == "login.tidal.com")
    #expect(value("client_id") == "abc")
    #expect(value("code_challenge") == "xyz")
    #expect(value("code_challenge_method") == "S256")
    #expect(value("redirect_uri") == "http://localhost:7412/tidal/callback")
    #expect(value("scope")?.split(separator: " ").contains("playlists.write") == true)
    #expect(value("state") == "s1")
}

@Test func formBodyEncodesReservedCharacters() {
    let s = String(decoding: TidalAuth.form([("code", "a+b/c=d"), ("x", "é y")]), as: UTF8.self)
    #expect(s == "code=a%2Bb%2Fc%3Dd&x=%C3%A9%20y")
}

@Test func tokenResponseKeepsRefreshToken() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let first = try TidalAuth.tokens(from: Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.utf8), now: now)
    #expect(first.access == "a1" && first.refresh == "r1" && first.expires == now.addingTimeInterval(3600))
    // ohne neuen Refresh-Token bleibt der alte
    let again = try TidalAuth.tokens(from: Data(#"{"access_token":"a2","expires_in":60}"#.utf8), now: now, keepRefresh: "r1")
    #expect(again.access == "a2" && again.refresh == "r1")
    #expect(throws: TidalError.self) { try TidalAuth.tokens(from: Data(#"{"access_token":"a3"}"#.utf8), now: now) }
}

@Test func playlistNameFromPattern() {
    #expect(TidalMatch.playlistName(pattern: TidalMatch.defaultPattern, year: 2026, month: 10, day: 16) == "missing-261016")
    #expect(TidalMatch.playlistName(pattern: "%Y-%m-%d", year: 2026, month: 1, day: 5) == "2026-01-05")
    #expect(TidalMatch.playlistName(pattern: " ", year: 2026, month: 10, day: 16) == "missing-261016")
}

@Test func foldIgnoresCaseAccentsAndPunctuation() {
    #expect(TidalMatch.fold("Éléphant, Straße!") == "elephant strasse")
}

@Test func titleSuffixesAreIgnored() {
    #expect(TidalMatch.baseTitle("Song (Original Mix)") == "Song")
    #expect(TidalMatch.baseTitle("Song [Remastered 2011]") == "Song")
    #expect(TidalMatch.baseTitle("Song - Radio Edit") == "Song")
    #expect(TidalMatch.baseTitle("Song - Part 2") == "Song - Part 2")
}

@Test func matchNeedsTitleArtistAndDuration() {
    let c = TidalCandidate(id: "1", title: "Halcyon (Original Mix)", artist: "Ocean Ash, Lulu", duration: 302)
    #expect(TidalMatch.passes(title: "Halcyon", artist: "Ocean Ash", duration: 300, c))
    #expect(!TidalMatch.passes(title: "Halcyon", artist: "Ocean Ash", duration: 320, c))   // mehr als 5 s
    #expect(TidalMatch.passes(title: "Halcyon", artist: "Ocean Ash", duration: 0, c))      // Dauer unbekannt
    #expect(!TidalMatch.passes(title: "Halcyon", artist: "Someone", duration: 302, c))
    #expect(!TidalMatch.passes(title: "Halcyon II", artist: "Ocean Ash", duration: 302, c))
    #expect(TidalMatch.passes(title: "Halcyon", artist: "Ash & Lulu", duration: 302, c))   // Teil der Künstlerliste
}

@Test func bestTakesFirstPassingHit() {
    let cands = [
        TidalCandidate(id: "x", title: "Other", artist: "Ocean Ash", duration: 302),
        TidalCandidate(id: "y", title: "Halcyon", artist: "Ocean Ash", duration: 301),
        TidalCandidate(id: "z", title: "Halcyon", artist: "Ocean Ash", duration: 301),
    ]
    #expect(TidalMatch.best(title: "Halcyon", artist: "Ocean Ash", duration: 300, cands)?.id == "y")
    #expect(TidalMatch.best(title: "Missing", artist: "Ocean Ash", duration: 300, cands) == nil)
}

@Test func queryUsesArtistAndBaseTitle() {
    #expect(TidalMatch.query(artist: "Ocean Ash", title: "Halcyon (Original Mix)") == "Ocean Ash Halcyon")
    #expect(TidalMatch.query(artist: " ", title: "Halcyon") == "Halcyon")
}

@Test func isoDurationParses() {
    #expect(TidalClient.isoDuration("PT2M58S") == 178)
    #expect(TidalClient.isoDuration("PT1H3.5S") == 3603.5)
    #expect(TidalClient.isoDuration("") == 0)
}

@Test func playlistBodyIsJSONAPI() throws {
    let o = try JSONSerialization.jsonObject(with: TidalClient.playlistBody(name: "missing-261016", description: "d")) as? [String: Any]
    let data = o?["data"] as? [String: Any]
    #expect(data?["type"] as? String == "playlists")
    let attr = data?["attributes"] as? [String: Any]
    #expect(attr?["name"] as? String == "missing-261016")
    #expect(attr?["accessType"] as? String == "UNLISTED")
}

@Test func itemsBodyListsTracks() throws {
    let o = try JSONSerialization.jsonObject(with: TidalClient.itemsBody(["11", "22"])) as? [String: Any]
    let items = o?["data"] as? [[String: Any]]
    #expect(items?.count == 2)
    #expect(items?.first?["type"] as? String == "tracks")
    #expect(items?.first?["id"] as? String == "11")
}

@Test func searchAndArtistFixturesParse() {
    let search = Data(#"{"data":{"id":"s","type":"searchResults"},"included":[{"id":"9","type":"tracks","attributes":{"title":"Halcyon","duration":"PT5M2S"}},{"id":"3","type":"artists","attributes":{"name":"Ocean Ash"}}]}"#.utf8)
    let c = TidalClient.parseSearch(search)
    #expect(c.map(\.id) == ["9"])
    #expect(c.first?.title == "Halcyon" && c.first?.duration == 302)
    let tracks = Data(#"{"data":[{"id":"9","type":"tracks","relationships":{"artists":{"data":[{"id":"3","type":"artists"}]}}}],"included":[{"id":"3","type":"artists","attributes":{"name":"Ocean Ash"}}]}"#.utf8)
    #expect(TidalClient.parseArtists(tracks) == ["9": "Ocean Ash"])
    #expect(TidalClient.parseCountry(Data(#"{"data":{"id":"me","attributes":{"country":"DE"}}}"#.utf8)) == "DE")
    #expect(TidalClient.playlistID(Data(#"{"data":{"id":"p1","type":"playlists"}}"#.utf8)) == "p1")
}
