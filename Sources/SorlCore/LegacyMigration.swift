import Foundation

/// One-time move of an Undertone install's data to Sorl: the whole preferences domain (Up next, Saved, Recent,
/// positions, speed, hotkeys and the rest) and the downloaded audio. Runs before anything reads settings or the cache.
public enum LegacyMigration {
    public static let legacyBundleID = "com.jverissimo.undertone"
    /// Set once the migration has run, whatever it found, so it never runs twice.
    public static let doneKey = "migratedFromUndertone"

    public struct Outcome: Equatable, Sendable {
        public var copiedKeys = 0
        public var movedAudio = false

        public init(copiedKeys: Int = 0, movedAudio: Bool = false) {
            self.copiedKeys = copiedKeys
            self.movedAudio = movedAudio
        }
    }

    /// Copies Undertone's preferences into `defaults` and moves its audio cache into Sorl's. Does nothing once done.
    @discardableResult
    public static func run(defaults: UserDefaults, bundleID: String, cachesDirectory: URL,
                           legacyID: String = legacyBundleID, fileManager: FileManager = .default) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return Outcome() }
        var outcome = Outcome()
        outcome.copiedKeys = copyDefaults(from: defaults.persistentDomain(forName: legacyID),
                                          existing: defaults.persistentDomain(forName: bundleID), into: defaults)
        outcome.movedAudio = moveAudio(from: cachesDirectory.appending(path: legacyID).appending(path: "Audio"),
                                       to: cachesDirectory.appending(path: bundleID).appending(path: "Audio"),
                                       fileManager: fileManager)
        defaults.set(true, forKey: doneKey)
        return outcome
    }

    /// Copies every key of `legacy` into `defaults`, unless Sorl already has settings of its own (`existing`), which
    /// always win. Returns how many keys were copied.
    static func copyDefaults(from legacy: [String: Any]?, existing: [String: Any]?, into defaults: UserDefaults) -> Int {
        guard let legacy, !legacy.isEmpty else { return 0 }
        guard (existing ?? [:]).keys.allSatisfy({ $0 == doneKey }) else { return 0 }
        for (key, value) in legacy { defaults.set(value, forKey: key) }
        return legacy.count
    }

    /// Moves the old audio directory into place when Sorl has none yet. A move on the same volume is a rename, so
    /// gigabytes of audio cost nothing. Returns whether it moved.
    static func moveAudio(from old: URL, to new: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: old.path) else { return false }
        if let contents = try? fileManager.contentsOfDirectory(atPath: new.path) {
            guard contents.isEmpty else { return false }
            try? fileManager.removeItem(at: new)
        }
        do {
            try fileManager.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: old, to: new)
            return true
        } catch {
            return false
        }
    }
}
