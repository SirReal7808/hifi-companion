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
            applyAcceptedDetectionIfNeeded(force: true)
        }
    }
    @Published private(set) var detectedFormat: AudioFormatInfo?
    @Published private(set) var deviceFormat: AudioFormatInfo?
    @Published private(set) var statusTitle = "HiFi"
    @Published private(set) var lastError: String?

    private let deviceManager = AudioDeviceManager()
    private let detector = MusicFormatDetector()
    private var switchGate = FormatSwitchGate(settleWindow: 3.0)
    private var acceptedDetection: FormatDetection?
    private var detectorTask: Task<Void, Never>?
    private var devicePollTimer: Timer?
    private var trackMonitor: MusicTrackMonitor?

    private static let pinnedDeviceKey = "pinnedOutputDeviceUID"

    private init() {
        pinnedDeviceUID = UserDefaults.standard.string(forKey: Self.pinnedDeviceKey)
    }

    var pinnedDevice: AudioOutputDevice? {
        guard let uid = pinnedDeviceUID else { return nil }
        return devices.first(where: { $0.uid == uid })
    }

    func start() {
        refreshDevices()
        refreshPinnedDeviceFormat()
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

        devicePollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshPinnedDeviceFormat()
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
        applyAcceptedDetectionIfNeeded(force: false)
        updateStatusTitle()
    }

    private func applyAcceptedDetectionIfNeeded(force: Bool) {
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
        if let format = deviceFormat {
            statusTitle = format.shortDescription
        } else if let format = detectedFormat {
            statusTitle = format.shortDescription
        } else {
            statusTitle = "HiFi"
        }
    }
}
