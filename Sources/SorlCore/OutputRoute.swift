/// When a change of the system's default output device should pause playback. Like Music.app: only when the
/// device being left went away (headphones unplugged, AirPods or a Bluetooth speaker disconnected). Plugging
/// something in, or picking another output in Sound settings, leaves the old device present and keeps playing.
public enum OutputRoute {
    /// - Parameters:
    ///   - previous: the default output device before the change (a CoreAudio device ID; 0 is "unknown").
    ///   - current: the default output device now.
    ///   - previousStillPresent: whether `previous` is still listed and alive.
    public static func shouldPause(isPlaying: Bool, previous: UInt32, current: UInt32, previousStillPresent: Bool) -> Bool {
        guard isPlaying, previous != current, previous != 0 else { return false }
        return !previousStillPresent
    }
}
