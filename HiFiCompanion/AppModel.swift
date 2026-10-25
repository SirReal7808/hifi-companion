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
            applyAcceptedDetectionIfNeeded(force: true)
        }
    }
    @Published private(set) var detectedFormat: AudioFormatInfo?
    @Published private(set) var deviceFormat: AudioFormatInfo?
    @Published private(set) var statusTitle = "HiFi"
    @Published private(set) var lastError: String?
    /// True while another audible app is using the pinned DAC (Apple Music mode lock).
    @Published private(set) var isMatchingLocked = false
    @Published private(set) var competingClientSummary: String?

    private let deviceManager = AudioDeviceManager()
    private let clientProbe = DeviceAudioClientProbe()
    private let detector = MusicFormatDetector()
    private var switchGate = FormatSwitchGate(settleWindow: 3.0)
    private var exclusiveLock = ExclusiveMusicLock()
    private var acceptedDetection: FormatDetection?
    private var detectorTask: Task<Void, Never>?
    private var devicePollTimer: Timer?
    private var trackMonitor: MusicTrackMonitor?

    private static let pinnedDeviceKey = "pinnedOutputDeviceUID"

    /// Shown in the menu under matching status.
    static let appleMusicModeMenuNote =
        "Apple Music mode switches only while Music is the only app using this device."

    private init() {
        pinnedDeviceUID = UserDefaults.standard.string(forKey: Self.pinnedDeviceKey)
    }

    var pinnedDevice: AudioOutputDevice? {
        guard let uid = pinnedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid })
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

        // Poll devices + exclusive-Music lock often enough to catch YouTube starting/stopping
        // without reacting to sub-second notification chirps (grace lives in ExclusiveMusicLock).
        devicePollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshPinnedDeviceFormat()
                self?.refreshExclusiveLock()
            }
        }
    }

    func stop() {
        detectorTask?.cancel()
        detectorTask = nil
        trackMonitor?.stop()
        trackMonitor = nil
        detector.stop()
        devicePollTimer?.invalidate()
        devicePollTimer = nil
    }

    func refreshDevices() {
        devices = deviceManager.outputDevices()
        if let uid = pinnedDeviceUID, !devices.contains(where: { $0.uid == uid }) {
            // Keep the pin; device may be temporarily disconnected.
        }
    }

    func pinDevice(_ device: AudioOutputDevice?) {
        pinnedDeviceUID = device?.uid
    }

    func isPinned(_ device: AudioOutputDevice) -> Bool {
        device.uid == pinnedDeviceUID
    }

    private func handleTrackChanged() {
        // Opens a short window where a newer ALAC downgrade may bypass post-upswitch settle.
        // Do not replay the last raw detection — it may still describe the previous track.
        switchGate.noteTrackChanged()
    }

    private func handleDetection(_ detection: FormatDetection) {
        guard case .apply(let accepted) = switchGate.consider(detection) else { return }
        acceptedDetection = accepted
        detectedFormat = accepted.format
        // While locked, remember the track format but do not reclock the DAC.
        if !isMatchingLocked {
            applyAcceptedDetectionIfNeeded(force: false)
        }
        updateStatusTitle()
    }

    private func refreshExclusiveLock() {
        guard let device = pinnedDevice ?? deviceManager.defaultOutputDevice() else {
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
            // Catch up to the current Music track now that we are alone on the DAC again.
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
        guard let device = pinnedDevice ?? deviceManager.defaultOutputDevice() else {
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
                to: device.id
            )
            switchGate.didApply(detection, previouslyApplied: previous)
            deviceFormat = applied
            lastError = nil
            updateStatusTitle()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshPinnedDeviceFormat() {
        guard let device = pinnedDevice ?? deviceManager.defaultOutputDevice() else {
            deviceFormat = nil
            updateStatusTitle()
            return
        }
        deviceFormat = deviceManager.currentFormat(for: device.id)
        updateStatusTitle()
    }

    private func updateStatusTitle() {
        if isMatchingLocked {
            statusTitle = "Locked"
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
