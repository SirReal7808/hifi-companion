import AppKit
import CoreAudio
import Foundation

/// Notifies on macOS output changes, device plug / unplug, wake from sleep, state changes of
/// the watched output device, and apps starting / stopping audio output. Core Audio listeners
/// deliver on the main queue; callbacks run on the main actor. Replaces polling.
@MainActor
final class OutputMonitor {
    enum Event {
        case systemOutputChanged
        /// Device list changed; `added` / `removed` are device UIDs.
        case devicesChanged(added: Set<String>, removed: Set<String>)
        case didWake
        /// Nominal rate, exclusive (hog) owner, or alive state of the watched device changed.
        case outputDeviceStateChanged
        /// An app started / stopped output or changed its devices (exclusive-Music lock).
        case processActivityChanged
    }

    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)

    var onEvent: (Event) -> Void = { _ in }

    private let deviceManager: AudioDeviceManager
    private var knownUIDs: Set<String> = []
    private var listeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var watchedDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var processListeners: [AudioObjectID: [Listener]] = [:]
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
        addSystemListener(kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.syncProcessListeners()
            self?.onEvent(.processActivityChanged)
        }
        syncProcessListeners()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onEvent(.didWake) }
        }
    }

    func stop() {
        remove(&listeners)
        remove(&deviceListeners)
        watchedDeviceID = AudioObjectID(kAudioObjectUnknown)
        for key in Array(processListeners.keys) {
            remove(&processListeners[key, default: []])
        }
        processListeners.removeAll()
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

    /// Watch rate, exclusive owner and alive state of the device we process (nil = none).
    func watchOutputDevice(_ deviceID: AudioObjectID?) {
        let id = deviceID ?? AudioObjectID(kAudioObjectUnknown)
        guard id != watchedDeviceID else { return }
        remove(&deviceListeners)
        watchedDeviceID = id
        guard id != kAudioObjectUnknown else { return }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyHogMode, kAudioDevicePropertyDeviceIsAlive] {
            if let listener = makeListener(object: id, selector: selector, handler: { [weak self] in
                self?.onEvent(.outputDeviceStateChanged)
            }) {
                deviceListeners.append(listener)
            }
        }
    }

    /// Keep one IsRunningOutput + Devices listener per Core Audio process object.
    private func syncProcessListeners() {
        let current = Set(Self.processObjectIDs())
        for gone in Set(processListeners.keys).subtracting(current) {
            remove(&processListeners[gone, default: []])
            processListeners[gone] = nil
        }
        for new in current.subtracting(processListeners.keys) {
            var added: [Listener] = []
            for selector in [kAudioProcessPropertyIsRunningOutput, kAudioProcessPropertyDevices] {
                // Wildcard: the HAL may notify these in the output scope.
                if let listener = makeListener(object: new, selector: selector, wildcard: true, handler: { [weak self] in
                    self?.onEvent(.processActivityChanged)
                }) {
                    added.append(listener)
                }
            }
            processListeners[new] = added
        }
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func addSystemListener(_ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        if let listener = makeListener(object: AudioObjectID(kAudioObjectSystemObject), selector: selector, handler: handler) {
            listeners.append(listener)
        }
    }

    private func makeListener(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        wildcard: Bool = false,
        handler: @escaping @MainActor () -> Void
    ) -> Listener? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: wildcard ? kAudioObjectPropertyScopeWildcard : kAudioObjectPropertyScopeGlobal,
            mElement: wildcard ? kAudioObjectPropertyElementWildcard : kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { handler() }
        }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return (object, address, block)
    }

    /// Removing from an object that no longer exists fails harmlessly.
    private func remove(_ list: inout [Listener]) {
        for listener in list {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        }
        list.removeAll()
    }
}
