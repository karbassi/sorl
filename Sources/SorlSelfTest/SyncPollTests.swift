import Foundation
import Testing
@testable import SorlCore

@Suite struct SyncPollTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var ready: SyncPoll.Conditions {
        .init(syncEnabled: true, isDemo: false, engineRunning: true, keyReady: true, isAsleep: false, isScreenLocked: false)
    }

    @Test func runsOnlyWhenEverythingIsReady() {
        #expect(SyncPoll.shouldRun(ready))
        var c = ready; c.syncEnabled = false
        #expect(!SyncPoll.shouldRun(c))
        c = ready; c.isDemo = true
        #expect(!SyncPoll.shouldRun(c))
        c = ready; c.engineRunning = false
        #expect(!SyncPoll.shouldRun(c))
        c = ready; c.keyReady = false
        #expect(!SyncPoll.shouldRun(c))
        c = ready; c.isAsleep = true
        #expect(!SyncPoll.shouldRun(c))
        c = ready; c.isScreenLocked = true
        #expect(!SyncPoll.shouldRun(c))
    }

    @Test func intervalIsAboutFiveMinutesWithTolerance() {
        #expect(SyncPoll.interval == 300)
        #expect(SyncPoll.tolerance > 0 && SyncPoll.tolerance < SyncPoll.interval)
    }

    @Test func delayWithNoFetchIsAFullInterval() {
        #expect(SyncPoll.delay(lastSuccess: nil, now: now) == SyncPoll.interval)
    }

    @Test func delayCountsFromTheLastSuccess() {
        #expect(SyncPoll.delay(lastSuccess: now, now: now) == 300)
        #expect(SyncPoll.delay(lastSuccess: now - 120, now: now) == 180)
    }

    @Test func overdueDelayIsZero() {
        #expect(SyncPoll.delay(lastSuccess: now - 3_600, now: now) == 0)
    }

    @Test func clockSetBackNeverWaitsLongerThanAnInterval() {
        #expect(SyncPoll.delay(lastSuccess: now + 3_600, now: now) == 300)
    }
}
