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

    @Test func dataSourceCodesMatchCoreAudio() {
        #expect(OutputRoute.headphones == 0x6864_706E)        // 'hdpn'
        #expect(OutputRoute.internalSpeakers == 0x6973_706B)  // 'ispk'
    }

    @Test func pausesWhenWiredHeadphonesAreUnplugged() {
        #expect(OutputRoute.shouldPause(isPlaying: true, fromDataSource: OutputRoute.headphones, toDataSource: OutputRoute.internalSpeakers))
    }

    @Test func keepsPlayingOnOtherDataSourceChanges() {
        // Headphones plugged in.
        #expect(!OutputRoute.shouldPause(isPlaying: true, fromDataSource: OutputRoute.internalSpeakers, toDataSource: OutputRoute.headphones))
        // Not playing.
        #expect(!OutputRoute.shouldPause(isPlaying: false, fromDataSource: OutputRoute.headphones, toDataSource: OutputRoute.internalSpeakers))
        // Some other source.
        #expect(!OutputRoute.shouldPause(isPlaying: true, fromDataSource: OutputRoute.headphones, toDataSource: OutputRoute.fourCC("line")))
    }
}
