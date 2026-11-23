import Testing
@testable import SorlCore

@Suite struct OutputRouteTests {
    @Test func pausesWhenTheDeviceBeingLeftWentAway() {
        #expect(OutputRoute.shouldPause(isPlaying: true, previous: 80, current: 72, previousStillPresent: false))
    }

    @Test func keepsPlayingWhenTheOldDeviceIsStillThere() {
        // Headphones plugged in, or another output picked in Sound settings.
        #expect(!OutputRoute.shouldPause(isPlaying: true, previous: 72, current: 80, previousStillPresent: true))
    }

    @Test func ignoresNoOpsAndUnknowns() {
        #expect(!OutputRoute.shouldPause(isPlaying: false, previous: 80, current: 72, previousStillPresent: false))
        #expect(!OutputRoute.shouldPause(isPlaying: true, previous: 80, current: 80, previousStillPresent: false))
        #expect(!OutputRoute.shouldPause(isPlaying: true, previous: 0, current: 72, previousStillPresent: false))
    }
}
