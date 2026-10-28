import AppKit
import CoreAudio
import Foundation

/// Notifies on macOS output changes, device plug / unplug, and wake from sleep.
/// Core Audio listeners deliver on the main queue; callbacks run on the main actor.
@MainActor
final class OutputMonitor {
    enum Event {
        case systemOutputChanged
        /// Device list changed; `added` / `removed` are device UIDs.
        case devicesChanged(added: Set<String>, removed: Set<String>)
        case didWake
    }

    var onEvent: (Event) -> Void = { _ in }

    private let deviceManager: AudioDeviceManager
    private var knownUIDs: Set<String> = []
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var wakeObserver: NSObjectProtocol?

    init(deviceManager: AudioDeviceManager) {
        self.deviceManager = deviceManager
    }

    /// UIDs of the output devices seen at the last check.
    var currentUIDs: Set<String> { knownUIDs }

    func start() {
        stop()
        knownUIDs = Set(deviceManager.outputDevices().map(\.uid))
        addSystemListener(kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.onEvent(.systemOutputChanged)
        }
        addSystemListener(kAudioHardwarePropertyDevices) { [weak self] in
            self?.devicesChanged()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent(.didWake) }
        }
    }

    func stop() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    private func devicesChanged() {
        let now = Set(deviceManager.outputDevices().map(\.uid))
        let added = now.subtracting(knownUIDs)
        let removed = knownUIDs.subtracting(now)
        knownUIDs = now
        guard !added.isEmpty || !removed.isEmpty else { return }
        onEvent(.devicesChanged(added: added, removed: removed))
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main, block
        )
        if status == noErr {
            listeners.append((address, block))
        }
    }
}
