import CoreAudio
import os

/// Pauses playback when the system's default output device changes (headphones unplugged, AirPods or a
/// Bluetooth speaker dropping), like Music.app does. AVPlayer would otherwise carry on out of the next device.
final class OutputDeviceWatcher {
    private let engine: PlayerEngine
    private let log = Logger(subsystem: "com.karbassi.sorl", category: "output")
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var listener: AudioObjectPropertyListenerBlock?
    private var device: AudioDeviceID

    init(engine: PlayerEngine) {
        self.engine = engine
        device = Self.defaultOutputDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(Self.system, &address, .main, block)
        if status == noErr {
            listener = block
        } else {
            log.error("couldn't watch the default output device: \(status)")
        }
    }

    /// Call on shutdown; the listener otherwise outlives the app's teardown.
    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(Self.system, &address, .main, listener)
        self.listener = nil
    }

    private func defaultOutputChanged() {
        let current = Self.defaultOutputDevice()
        guard current != device else { return }
        log.notice("default output device changed \(self.device) -> \(current), playing: \(self.engine.isPlaying)")
        device = current
        if engine.isPlaying { engine.pause() }
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(Self.system, &address, 0, nil, &size, &id)
        return id
    }
}
