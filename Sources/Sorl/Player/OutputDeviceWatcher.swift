import CoreAudio
import SorlCore
import os

/// Pauses playback when the output device being played through goes away (headphones unplugged, AirPods or a
/// Bluetooth speaker dropping), like Music.app does. AVPlayer would otherwise carry on out of the next device.
/// Plugging something in or picking another output keeps playing: the old device is still there (`OutputRoute`).
final class OutputDeviceWatcher {
    private let engine: PlayerEngine
    private let log = Logger(subsystem: "com.karbassi.sorl", category: "output")
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private var address = OutputDeviceWatcher.address(kAudioHardwarePropertyDefaultOutputDevice)
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
        let previous = device
        let current = Self.defaultOutputDevice()
        guard current != previous else { return }
        device = current
        let present = Self.isPresent(previous)
        log.notice("default output \(previous) -> \(current), old still present: \(present), playing: \(self.engine.isPlaying)")
        if OutputRoute.shouldPause(isPlaying: engine.isPlaying, previous: previous, current: current, previousStillPresent: present) {
            engine.pause()
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }

    /// Whether `id` is still in the system's device list and alive.
    private static func isPresent(_ id: AudioDeviceID) -> Bool {
        var listAddress = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return true }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &devices) == noErr else { return true }
        guard devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).contains(id) else { return false }

        var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var aliveSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &aliveAddress, 0, nil, &aliveSize, &alive) == noErr else { return false }
        return alive != 0
    }
}
