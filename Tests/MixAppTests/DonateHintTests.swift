import Foundation
import Testing
@testable import MixApp

@Test func donateHintRule() {
    let now = Date()
    #expect(DonateHint.due(mode: .always, donated: false, lastShown: nil, now: now))
    #expect(!DonateHint.due(mode: .always, donated: true, lastShown: nil, now: now))
    #expect(!DonateHint.due(mode: .never, donated: false, lastShown: nil, now: now))
    #expect(DonateHint.due(mode: .weekly, donated: false, lastShown: nil, now: now))
    #expect(!DonateHint.due(mode: .weekly, donated: false, lastShown: now.addingTimeInterval(-3 * 86400), now: now))
    #expect(DonateHint.due(mode: .weekly, donated: false, lastShown: now.addingTimeInterval(-8 * 86400), now: now))
    #expect(DonateHint.url.host()?.contains("paypal.com") == true)
}
