import Foundation

/// The background poll that picks up iCloud changes when a CloudKit push is late or never arrives.
///
/// `CloudSync` owns the timer; this holds the decisions, so they can be tested without CloudKit.
public enum SyncPoll {
    /// About five minutes between polls; any successful fetch starts the wait over.
    public static let interval: TimeInterval = 300
    /// Lets the system batch the wake-up with other work.
    public static let tolerance: TimeInterval = 60

    public struct Conditions: Equatable, Sendable {
        public var syncEnabled: Bool
        public var isDemo: Bool
        /// An engine exists and isn't only listening for account changes (signed out).
        public var engineRunning: Bool
        /// The account's sync key is known, which means the account was available and the first sync finished.
        public var keyReady: Bool
        public var isAsleep: Bool
        public var isScreenLocked: Bool

        public init(syncEnabled: Bool, isDemo: Bool, engineRunning: Bool, keyReady: Bool,
                    isAsleep: Bool, isScreenLocked: Bool) {
            self.syncEnabled = syncEnabled
            self.isDemo = isDemo
            self.engineRunning = engineRunning
            self.keyReady = keyReady
            self.isAsleep = isAsleep
            self.isScreenLocked = isScreenLocked
        }
    }

    /// Whether a poll timer should exist at all.
    public static func shouldRun(_ c: Conditions) -> Bool {
        c.syncEnabled && !c.isDemo && c.engineRunning && c.keyReady && !c.isAsleep && !c.isScreenLocked
    }

    /// Seconds until the next poll: a full interval after the last successful fetch, or now if that is overdue
    /// (after waking, say). With no fetch yet, a full interval, since starting sync fetches on its own.
    public static func delay(lastSuccess: Date?, now: Date, interval: TimeInterval = interval) -> TimeInterval {
        guard let lastSuccess else { return interval }
        let elapsed = now.timeIntervalSince(lastSuccess)
        // A clock set backwards makes `elapsed` negative; never wait longer than one interval.
        return min(interval, max(0, interval - elapsed))
    }
}
