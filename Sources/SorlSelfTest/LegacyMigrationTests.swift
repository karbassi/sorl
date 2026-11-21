import Foundation
import Testing
@testable import SorlCore

@Suite struct LegacyMigrationTests {
    /// A throwaway domain pair and caches folder, so nothing touches the real Undertone or Sorl data.
    struct Sandbox {
        let id = UUID().uuidString
        var legacyID: String { "test.undertone.\(id)" }
        var bundleID: String { "test.sorl.\(id)" }
        let caches = FileManager.default.temporaryDirectory.appending(path: "sorl-migration-\(UUID().uuidString)")
        var defaults: UserDefaults { UserDefaults(suiteName: bundleID)! }

        func legacyAudio() -> URL { caches.appending(path: legacyID).appending(path: "Audio") }
        func newAudio() -> URL { caches.appending(path: bundleID).appending(path: "Audio") }

        func run() -> LegacyMigration.Outcome {
            LegacyMigration.run(defaults: defaults, bundleID: bundleID, cachesDirectory: caches, legacyID: legacyID)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: bundleID)
            defaults.removePersistentDomain(forName: legacyID)
            try? FileManager.default.removeItem(at: caches)
        }
    }

    @Test func copiesEveryLegacyKeyAndMovesTheAudio() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        let saved = Data("saved".utf8)
        box.defaults.setPersistentDomain(["savedLinks": saved, "speed": 1.5, "KeyboardShortcuts_togglePanel": "{}"],
                                         forName: box.legacyID)
        try FileManager.default.createDirectory(at: box.legacyAudio(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 10).write(to: box.legacyAudio().appending(path: "abc.m4a"))

        let outcome = box.run()

        #expect(outcome == LegacyMigration.Outcome(copiedKeys: 3, movedAudio: true))
        #expect(box.defaults.data(forKey: "savedLinks") == saved)
        #expect(box.defaults.double(forKey: "speed") == 1.5)
        #expect(box.defaults.string(forKey: "KeyboardShortcuts_togglePanel") == "{}")
        #expect(FileManager.default.fileExists(atPath: box.newAudio().appending(path: "abc.m4a").path))
        #expect(!FileManager.default.fileExists(atPath: box.legacyAudio().path))
    }

    @Test func runsOnlyOnce() {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.defaults.setPersistentDomain(["speed": 1.5], forName: box.legacyID)
        #expect(box.run().copiedKeys == 1)
        box.defaults.set(2.0, forKey: "speed")
        #expect(box.run() == LegacyMigration.Outcome())
        #expect(box.defaults.double(forKey: "speed") == 2.0)
    }

    @Test func neverOverwritesSorlsOwnData() throws {
        let box = Sandbox()
        defer { box.cleanUp() }
        box.defaults.setPersistentDomain(["speed": 1.5], forName: box.legacyID)
        box.defaults.set(0.75, forKey: "speed")
        try FileManager.default.createDirectory(at: box.legacyAudio(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: box.newAudio(), withIntermediateDirectories: true)
        try Data().write(to: box.newAudio().appending(path: "new.m4a"))

        #expect(box.run() == LegacyMigration.Outcome())
        #expect(box.defaults.double(forKey: "speed") == 0.75)
        #expect(FileManager.default.fileExists(atPath: box.legacyAudio().path))
    }

    @Test func freshInstallJustMarksItDone() {
        let box = Sandbox()
        defer { box.cleanUp() }
        #expect(box.run() == LegacyMigration.Outcome())
        #expect(box.defaults.bool(forKey: LegacyMigration.doneKey))
    }
}
