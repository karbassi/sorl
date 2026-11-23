/// When a change of the system's audio output should pause playback. Like Music.app: only when the output being
/// left went away (headphones unplugged, AirPods or a Bluetooth speaker disconnected). Plugging something in, or
/// picking another output in Sound settings, keeps playing.
public enum OutputRoute {
    /// CoreAudio data source codes on a Mac's built-in output device.
    public static let headphones = fourCC("hdpn")
    public static let internalSpeakers = fourCC("ispk")

    /// A change of the default output device.
    /// - Parameters:
    ///   - previous: the default output device before the change (a CoreAudio device ID; 0 is "unknown").
    ///   - current: the default output device now.
    ///   - previousStillPresent: whether `previous` is still listed and alive.
    public static func shouldPause(isPlaying: Bool, previous: UInt32, current: UInt32, previousStillPresent: Bool) -> Bool {
        guard isPlaying, previous != current, previous != 0 else { return false }
        return !previousStillPresent
    }

    /// A change of the built-in device's data source: on a MacBook, unplugging wired headphones flips it from
    /// headphones to internal speakers while the default device stays the same.
    public static func shouldPause(isPlaying: Bool, fromDataSource: UInt32, toDataSource: UInt32) -> Bool {
        isPlaying && fromDataSource == headphones && toDataSource == internalSpeakers
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
