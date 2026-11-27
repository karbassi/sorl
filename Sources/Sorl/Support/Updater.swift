import AppKit
import Observation
import os
import Sparkle

/// In-app updates through Sparkle. The feed is `appcast.xml` on the latest GitHub release (see release.yml);
/// updates and the feed are both EdDSA-signed, so a swapped download or feed is refused.
@MainActor @Observable
final class Updater: NSObject {
    /// False when Sparkle couldn't start, e.g. a `swift run` build with no app bundle.
    private(set) var isAvailable = false
    private(set) var canCheck = false
    /// "1.6.0" once a check finds a newer version; nil otherwise.
    private(set) var availableVersion: String?

    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private let log = Logger(subsystem: "com.karbassi.sorl", category: "update")

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            try controller.updater.start()
            isAvailable = true
        } catch {
            log.error("updater didn't start: \(error.localizedDescription, privacy: .public)")
        }
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecks) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    /// Shows Sparkle's window: "You're up to date", or the new version with Install.
    func checkNow() {
        guard isAvailable, canCheck else { return }
        // An accessory app's windows open behind the frontmost app unless it activates first.
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}

extension Updater: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            availableVersion = version
            log.notice("update available: \(version, privacy: .public)")
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { availableVersion = nil }
    }
}

extension Updater: SPUStandardUserDriverDelegate {
    /// Sorl lives in the menu bar, so a scheduled check shouldn't steal focus; Settings shows the update instead.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
