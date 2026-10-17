import Testing
@testable import MixApp

@Test func setupIsNeededOnlyForFirstLaunchMissingCollectionOrDevice() {
    // normaler Start: Collection da, Gerät da, Einstellungen da
    #expect(SetupFlow.reasons(firstLaunch: false, collectionFound: true, deviceMissing: false).isEmpty)
    #expect(SetupFlow.reasons(firstLaunch: true, collectionFound: true, deviceMissing: false) == [.firstLaunch])
    #expect(SetupFlow.reasons(firstLaunch: false, collectionFound: false, deviceMissing: false) == [.collectionMissing])
    #expect(SetupFlow.reasons(firstLaunch: false, collectionFound: true, deviceMissing: true) == [.deviceMissing])
    #expect(SetupFlow.reasons(firstLaunch: true, collectionFound: false, deviceMissing: true)
            == [.firstLaunch, .collectionMissing, .deviceMissing])
}

@Test func setupStepsAreInOrder() {
    #expect(SetupFlow.Step.allCases.map(\.number) == [1, 2, 3, 4, 5])
    #expect(SetupFlow.Step.allCases.last == .done)
}
