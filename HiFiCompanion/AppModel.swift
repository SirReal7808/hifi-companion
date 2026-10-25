import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published var pinnedDeviceUID: String? {
        didSet {
            UserDefaults.standard.set(pinnedDeviceUID, forKey: Self.pinnedDeviceKey)
            refreshPinnedDeviceFormat()
            refreshExclusiveLock()
            if isPassThroughEnabled {
                Task { await restartPassThroughBridge() }
            }
            applyAcceptedDetectionIfNeeded(force: true)
        }
    }
    @Published private(set) var detectedFormat: AudioFormatInfo?
    @Published private(set) var deviceFormat: AudioFormatInfo?
    @Published private(set) var statusTitle = "HiFi"
    @Published private(set) var lastError: String?
    /// True while another audible app is using the Music-facing device (Apple Music mode lock).
    @Published private(set) var isMatchingLocked = false
    @Published private(set) var competingClientSummary: String?
    @Published private(set) var isPassThroughEnabled = false
    @Published private(set) var virtualDeviceAvailable = false
    @Published private(set) var pathStatusText = "Matching only"
    /// Test EQ gain in dB. Only applied while pass-through is on.
    @Published private(set) var eqGainDB: Double = 0

    private let deviceManager = AudioDeviceManager()
    private let clientProbe = DeviceAudioClientProbe()
    private let detector = MusicFormatDetector()
    private let passThroughBridge = PassThroughBridge()
    private var switchGate = FormatSwitchGate(settleWindow: 3.0)
    private var exclusiveLock = ExclusiveMusicLock()
    private var acceptedDetection: FormatDetection?
    private var detectorTask: Task<Void, Never>?
    private var devicePollTimer: Timer?
    private var trackMonitor: MusicTrackMonitor?
    /// Default output UID captured when pass-through was enabled.
    private var previousDefaultOutputUID: String?

    private static let pinnedDeviceKey = "pinnedOutputDeviceUID"
    private static let previousDefaultKey = "passThroughPreviousDefaultUID"
    private static let eqGainKey = "testEQGainDB"

    /// Shown in the menu under matching status.
    static let appleMusicModeMenuNote =
        "Apple Music mode switches only while Music is the only app using this device."

    static let passThroughMenuNote =
        "Pass-through: apps play into BlackHole 2ch; HiFi Companion copies PCM to the pinned DAC."

    var testEQFrequencyHz: Double { passThroughBridge.testEQFrequencyHz }
    var testEQQ: Double { passThroughBridge.testEQQ }
    var isEQActive: Bool { isPassThroughEnabled && !passThroughBridge.isEQBypassed }

    var eqStatusText: String {
        guard isPassThroughEnabled else {
            return "EQ: off (matching-only is dry)"
        }
        if isEQActive {
            return String(format: "EQ: active %+0.1f dB @ %.0f Hz (not bit-perfect)", eqGainDB, testEQFrequencyHz)
        }
        return "EQ: bypassed (0 dB — dry pass-through)"
    }

    private init() {
        pinnedDeviceUID = UserDefaults.standard.string(forKey: Self.pinnedDeviceKey)
        previousDefaultOutputUID = UserDefaults.standard.string(forKey: Self.previousDefaultKey)
        let storedGain = UserDefaults.standard.object(forKey: Self.eqGainKey) as? Double ?? 0
        eqGainDB = storedGain
        passThroughBridge.setEQGainDB(storedGain)
    }

    func setEQGainDB(_ gainDB: Double) {
        let clamped = min(12, max(-12, gainDB))
        eqGainDB = clamped
        UserDefaults.standard.set(clamped, forKey: Self.eqGainKey)
        // DSP only runs while pass-through is on; matching-only stays dry.
        if isPassThroughEnabled {
            passThroughBridge.setEQGainDB(clamped)
        } else {
            passThroughBridge.setEQGainDB(0)
        }
        updatePathStatus()
        updateStatusTitle()
    }

    var pinnedDevice: AudioOutputDevice? {
        guard let uid = pinnedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid }) ?? deviceManager.device(uid: uid)
    }

    var matchingStatusText: String {
        if isMatchingLocked {
            if let summary = competingClientSummary, !summary.isEmpty {
                return "Locked: other audio (\(summary))"
            }
            return "Locked: other audio on this device"
        }
        return "Matching: Music alone"
    }

    func start() {
        refreshDevices()
        refreshPinnedDeviceFormat()
        refreshExclusiveLock()
        updatePathStatus()
        updateStatusTitle()

        let monitor = MusicTrackMonitor { [weak self] in
            Task { @MainActor in
                self?.handleTrackChanged()
            }
        }
        monitor.start()
        trackMonitor = monitor

        detectorTask = Task { [weak self] in
            guard let self else { return }
            for await detection in self.detector.detections() {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.handleDetection(detection)
                }
            }
        }

        devicePollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshPinnedDeviceFormat()
                self?.refreshExclusiveLock()
            }
        }
    }

    func stop() {
        disablePassThrough(restoreDefault: true)
        detectorTask?.cancel()
        detectorTask = nil
        trackMonitor?.stop()
        trackMonitor = nil
        detector.stop()
        devicePollTimer?.invalidate()
        devicePollTimer = nil
    }

    func refreshDevices() {
        devices = deviceManager.pinnableOutputDevices()
        virtualDeviceAvailable = deviceManager.preferredVirtualLoopback() != nil
        updatePathStatus()
    }

    func pinDevice(_ device: AudioOutputDevice?) {
        pinnedDeviceUID = device?.uid
    }

    func isPinned(_ device: AudioOutputDevice) -> Bool {
        device.uid == pinnedDeviceUID
    }

    func togglePassThrough() {
        Task {
            if isPassThroughEnabled {
                disablePassThrough(restoreDefault: true)
            } else {
                await enablePassThrough()
            }
        }
    }

    private func enablePassThrough() async {
        lastError = nil
        guard let virtual = deviceManager.preferredVirtualLoopback() else {
            lastError = PassThroughError.missingVirtualDevice.localizedDescription
            updatePathStatus()
            return
        }
        guard let dac = pinnedDevice ?? deviceManager.defaultOutputDevice() else {
            lastError = PassThroughError.missingDAC.localizedDescription
            return
        }
        if VirtualDeviceCatalog.isVirtualLoopback(uid: dac.uid, name: dac.name) {
            lastError = "Pin a real DAC before enabling pass-through (not BlackHole)."
            return
        }

        if !MicrophoneAccess.isGranted {
            let granted = await MicrophoneAccess.request()
            if !granted {
                lastError = PassThroughError.microphoneDenied.localizedDescription
                return
            }
        }

        // Remember the current default unless we already stored one from a previous enable.
        if previousDefaultOutputUID == nil {
            previousDefaultOutputUID = deviceManager.defaultOutputDevice()?.uid
            UserDefaults.standard.set(previousDefaultOutputUID, forKey: Self.previousDefaultKey)
        }

        do {
            // Align SB before opening the graph.
            if let format = acceptedDetection?.format ?? detectedFormat ?? deviceFormat {
                _ = try? deviceManager.apply(format: format, to: dac.id)
                _ = try? deviceManager.apply(format: format, to: virtual.id)
            }

            try deviceManager.setDefaultOutputDevice(id: virtual.id)
            passThroughBridge.setEQGainDB(eqGainDB)
            try passThroughBridge.start(inputDeviceID: virtual.id, outputDeviceID: dac.id)
            isPassThroughEnabled = true
            lastError = nil
            refreshExclusiveLock()
            updatePathStatus()
            updateStatusTitle()
        } catch {
            passThroughBridge.stop()
            if let previous = previousDefaultOutputUID {
                try? deviceManager.setDefaultOutputDevice(uid: previous)
            }
            isPassThroughEnabled = false
            passThroughBridge.setEQGainDB(0)
            lastError = error.localizedDescription
            updatePathStatus()
        }
    }

    private func disablePassThrough(restoreDefault: Bool) {
        passThroughBridge.stop()
        passThroughBridge.setEQGainDB(0)
        isPassThroughEnabled = false
        if restoreDefault, let previous = previousDefaultOutputUID {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
            previousDefaultOutputUID = nil
            UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        }
        refreshExclusiveLock()
        updatePathStatus()
        updateStatusTitle()
    }

    private func restartPassThroughBridge() async {
        guard isPassThroughEnabled else { return }
        guard let virtual = deviceManager.preferredVirtualLoopback() else {
            lastError = PassThroughError.missingVirtualDevice.localizedDescription
            disablePassThrough(restoreDefault: true)
            return
        }

        let output: AudioOutputDevice? = {
            if let pinned = pinnedDevice,
               !VirtualDeviceCatalog.isVirtualLoopback(uid: pinned.uid, name: pinned.name) {
                return pinned
            }
            if let prev = previousDefaultOutputUID,
               let device = deviceManager.device(uid: prev),
               !VirtualDeviceCatalog.isVirtualLoopback(uid: device.uid, name: device.name) {
                return device
            }
            if let fallback = deviceManager.defaultOutputDevice(),
               !VirtualDeviceCatalog.isVirtualLoopback(uid: fallback.uid, name: fallback.name) {
                return fallback
            }
            return nil
        }()

        guard let output else {
            lastError = "Pin a real DAC for pass-through."
            return
        }

        do {
            passThroughBridge.setEQGainDB(eqGainDB)
            try passThroughBridge.start(inputDeviceID: virtual.id, outputDeviceID: output.id)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updatePathStatus()
    }

    private func handleTrackChanged() {
        switchGate.noteTrackChanged()
    }

    private func handleDetection(_ detection: FormatDetection) {
        guard case .apply(let accepted) = switchGate.consider(detection) else { return }
        acceptedDetection = accepted
        detectedFormat = accepted.format
        if !isMatchingLocked {
            applyAcceptedDetectionIfNeeded(force: false)
        }
        updateStatusTitle()
    }

    /// Device where Music (and other apps) render when matching lock is evaluated.
    private func musicFacingDevice() -> AudioOutputDevice? {
        if isPassThroughEnabled {
            return deviceManager.preferredVirtualLoopback()
        }
        return pinnedDevice ?? deviceManager.defaultOutputDevice()
    }

    private func refreshExclusiveLock() {
        guard let device = musicFacingDevice() else {
            competingClientSummary = nil
            if isMatchingLocked {
                isMatchingLocked = false
                exclusiveLock.reset()
                updateStatusTitle()
            }
            return
        }

        let competitors = clientProbe.competingOutputClients(on: device.id)
        competingClientSummary = competitors.isEmpty
            ? nil
            : competitors.prefix(2).map(\.bundleID).joined(separator: ", ")

        let event = exclusiveLock.update(competingAudible: !competitors.isEmpty)
        let wasLocked = isMatchingLocked
        isMatchingLocked = exclusiveLock.isLocked

        switch event {
        case .locked:
            updateStatusTitle()
        case .unlocked:
            applyAcceptedDetectionIfNeeded(force: true)
            updateStatusTitle()
        case .unchanged:
            if wasLocked != isMatchingLocked {
                updateStatusTitle()
            }
        }
    }

    private func applyAcceptedDetectionIfNeeded(force: Bool) {
        guard !isMatchingLocked else { return }
        guard let detection = acceptedDetection else { return }
        guard let dacTarget = resolveHardwareDAC() else {
            lastError = "No output device available"
            return
        }

        if !force, let last = switchGate.lastApplied, last.format == detection.format {
            refreshPinnedDeviceFormat()
            return
        }

        do {
            let previous = switchGate.lastApplied
            let applied = try deviceManager.apply(
                format: detection.format,
                to: dacTarget.id
            )
            // Keep the virtual hop at the same SB so apps render at the matched rate.
            if let virtual = deviceManager.preferredVirtualLoopback() {
                _ = try? deviceManager.apply(format: detection.format, to: virtual.id)
            }
            switchGate.didApply(detection, previouslyApplied: previous)
            deviceFormat = applied
            lastError = nil

            if isPassThroughEnabled {
                Task { await restartPassThroughBridge() }
            }
            updateStatusTitle()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolveHardwareDAC() -> AudioOutputDevice? {
        if let pinned = pinnedDevice,
           !VirtualDeviceCatalog.isVirtualLoopback(uid: pinned.uid, name: pinned.name) {
            return pinned
        }
        if let prev = previousDefaultOutputUID,
           let device = deviceManager.device(uid: prev),
           !VirtualDeviceCatalog.isVirtualLoopback(uid: device.uid, name: device.name) {
            return device
        }
        if let fallback = deviceManager.defaultOutputDevice(),
           !VirtualDeviceCatalog.isVirtualLoopback(uid: fallback.uid, name: fallback.name) {
            return fallback
        }
        return nil
    }

    private func refreshPinnedDeviceFormat() {
        let device: AudioOutputDevice? = {
            if let pinned = pinnedDevice { return pinned }
            if isPassThroughEnabled, let prev = previousDefaultOutputUID {
                return deviceManager.device(uid: prev)
            }
            return deviceManager.defaultOutputDevice()
        }()
        guard let device else {
            deviceFormat = nil
            updateStatusTitle()
            return
        }
        deviceFormat = deviceManager.currentFormat(for: device.id)
        updateStatusTitle()
    }

    private func updatePathStatus() {
        if isPassThroughEnabled, let virtual = deviceManager.preferredVirtualLoopback() {
            let dacName = pinnedDevice?.name ?? "DAC"
            let eqTag = isEQActive ? String(format: " · EQ %+.0f dB", eqGainDB) : " · EQ bypass"
            pathStatusText = "Virtual → DAC (\(virtual.name) → \(dacName))\(eqTag)"
        } else if virtualDeviceAvailable {
            pathStatusText = "Matching only"
        } else {
            pathStatusText = "Matching only (install BlackHole 2ch for pass-through)"
        }
    }

    private func updateStatusTitle() {
        if isMatchingLocked {
            statusTitle = "Locked"
            return
        }
        if isPassThroughEnabled {
            if isEQActive {
                statusTitle = String(format: "EQ %+.0f dB", eqGainDB)
            } else if let format = deviceFormat {
                statusTitle = "PT \(format.shortDescription)"
            } else {
                statusTitle = "PT On"
            }
            return
        }
        if let format = deviceFormat {
            statusTitle = format.shortDescription
        } else if let format = detectedFormat {
            statusTitle = format.shortDescription
        } else {
            statusTitle = "HiFi"
        }
    }
}
