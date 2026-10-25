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
            applyDetectedFormatIfNeeded()
        }
    }
    @Published private(set) var detectedFormat: AudioFormatInfo?
    @Published private(set) var deviceFormat: AudioFormatInfo?
    @Published private(set) var statusTitle = "HiFi"
    @Published private(set) var lastError: String?

    private let deviceManager = AudioDeviceManager()
    private let detector = MusicFormatDetector()
    private var detectorTask: Task<Void, Never>?
    private var devicePollTimer: Timer?

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

        detectorTask = Task { [weak self] in
            guard let self else { return }
            for await format in self.detector.formats() {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.handleDetectedFormat(format)
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

    private func handleDetectedFormat(_ format: AudioFormatInfo) {
        detectedFormat = format
        applyDetectedFormatIfNeeded()
        updateStatusTitle()
    }

    private func applyDetectedFormatIfNeeded() {
        guard let format = detectedFormat else { return }
        guard let device = pinnedDevice ?? deviceManager.defaultOutputDevice() else {
            lastError = "No output device available"
            return
        }

        do {
            let applied = try deviceManager.apply(
                format: format,
                to: device.id
            )
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
