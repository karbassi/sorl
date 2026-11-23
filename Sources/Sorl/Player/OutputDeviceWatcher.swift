import CoreAudio
import Foundation
import SorlCore
import os

/// Pauses playback when the output being played through goes away, like Music.app does. AVPlayer would otherwise
/// carry on out of the next device. Two ways that happens:
/// - The default output device goes away (AirPods, a Bluetooth or USB device disconnecting).
/// - The built-in device's data source flips from headphones to speakers (a MacBook's wired headphones unplugged:
///   the jack is a data source on the built-in device, so the default device ID doesn't change).
/// Plugging something in or picking another output keeps playing (`OutputRoute`).
final class OutputDeviceWatcher {
    private let engine: PlayerEngine
    private let log = Logger(subsystem: "com.karbassi.sorl", category: "output")
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    /// How long to wait before re-checking a departed device that still looked present when the change fired.
    private static let recheckDelay: TimeInterval = 0.5
    private var defaultAddress = OutputDeviceWatcher.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var sourceAddress = OutputDeviceWatcher.address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var sourceListener: AudioObjectPropertyListenerBlock?
    private var device: AudioDeviceID
    private var dataSource: UInt32?

    init(engine: PlayerEngine) {
        self.engine = engine
        device = Self.defaultOutputDevice()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.defaultOutputChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(Self.system, &defaultAddress, .main, block)
        if status == noErr {
            defaultListener = block
        } else {
            log.error("couldn't watch the default output device: \(status)")
        }
        watchDataSource()
    }

    /// Call on shutdown; the listeners otherwise outlive the app's teardown.
    func stop() {
        unwatchDataSource()
        guard let defaultListener else { return }
        AudioObjectRemovePropertyListenerBlock(Self.system, &defaultAddress, .main, defaultListener)
        self.defaultListener = nil
    }

    // MARK: Default device

    private func defaultOutputChanged() {
        let previous = device
        let current = Self.defaultOutputDevice()
        guard current != previous else { return }
        unwatchDataSource()
        device = current
        watchDataSource()
        let present = Self.isPresent(previous)
        log.notice("default output \(previous) -> \(current), old still present: \(present), playing: \(self.engine.isPlaying)")
        decide(previous: previous, current: current, present: present)
        guard present, engine.isPlaying else { return }
        // The old device can still be listed and alive while it's being torn down. Look again shortly.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recheckDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.device == current else { return }
                self.decide(previous: previous, current: current, present: Self.isPresent(previous))
            }
        }
    }

    private func decide(previous: AudioDeviceID, current: AudioDeviceID, present: Bool) {
        if OutputRoute.shouldPause(isPlaying: engine.isPlaying, previous: previous, current: current, previousStillPresent: present) {
            log.notice("output \(previous) went away; pausing")
            engine.pause()
        }
    }

    // MARK: Data source (built-in headphone jack)

    private func watchDataSource() {
        dataSource = Self.dataSource(of: device)
        // Most devices have no data source; only watch the ones that do.
        guard dataSource != nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.dataSourceChanged() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &sourceAddress, .main, block) == noErr {
            sourceListener = block
        }
    }

    private func unwatchDataSource() {
        guard let sourceListener else { return }
        AudioObjectRemovePropertyListenerBlock(device, &sourceAddress, .main, sourceListener)
        self.sourceListener = nil
    }

    private func dataSourceChanged() {
        let previous = dataSource
        let current = Self.dataSource(of: device)
        dataSource = current
        guard let previous, let current, previous != current else { return }
        log.notice("output data source \(previous) -> \(current), playing: \(self.engine.isPlaying)")
        if OutputRoute.shouldPause(isPlaying: engine.isPlaying, fromDataSource: previous, toDataSource: current) {
            engine.pause()
        }
    }

    // MARK: CoreAudio reads

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        return id
    }

    /// The device's current output data source (e.g. 'hdpn', 'ispk'), or nil if it has none.
    private static func dataSource(of id: AudioDeviceID) -> UInt32? {
        var address = address(kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput)
        guard id != kAudioObjectUnknown, AudioObjectHasProperty(id, &address) else { return nil }
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr else { return nil }
        return source
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
