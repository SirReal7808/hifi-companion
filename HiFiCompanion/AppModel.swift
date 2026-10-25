import Combine
import Foundation
import os.log

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
    /// True only while the BlackHole → DAC bridge engine is actually running.
    @Published private(set) var isBridgeRunning = false
    @Published private(set) var virtualDeviceAvailable = false
    @Published private(set) var pathStatusText = "Matching only"
    /// Test EQ gain in dB. Only applied while pass-through is on.
    @Published private(set) var eqGainDB: Double = 0
    /// Short reason when Test EQ is disabled.
    @Published private(set) var testEQDisabledReason = "Enable Pass-through first"

    private let log = Logger(subsystem: "com.hificompanion.app", category: "AppModel")
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
    private var passThroughOp: Task<Void, Never>?

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
    var isEQActive: Bool { isBridgeRunning && !passThroughBridge.isEQBypassed }

    var eqStatusText: String {
        guard isBridgeRunning else {
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
        if isBridgeRunning {
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
        recoverOrphanedPassThroughDefault()
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
                self?.syncBridgeRunningFlag()
            }
        }
    }

    /// Headless check: start bridge briefly, print OK/FAIL lines, restore default. Used by `--smoke-passthrough`.
    func runPassThroughSmokeTest() async -> Int32 {
        refreshDevices()
        print("SMOKE: pinned=\(pinnedDevice?.name ?? "nil") virtual=\(deviceManager.preferredVirtualLoopback()?.name ?? "nil")")
        print("SMOKE: mic \(MicrophoneAccess.diagnosticSummary)")
        await enablePassThrough()
        let running = isBridgeRunning
        let err = lastError
        if running {
            print("SMOKE: OK bridge running path=\(pathStatusText)")
            print("SMOKE: no false Input-access-denied (lastError=\(err ?? "nil"))")
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            disablePassThrough(restoreDefault: true)
            print("SMOKE: OK bridge stopped; default restored")
            return 0
        }
        print("SMOKE: FAIL \(err ?? "bridge not running")")
        print("SMOKE: mic_after \(MicrophoneAccess.diagnosticSummary)")
        disablePassThrough(restoreDefault: true)
        return 1
    }

    func stop() {
        passThroughOp?.cancel()
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
        if let device, VirtualDeviceCatalog.isVirtualLoopback(uid: device.uid, name: device.name) {
            lastError = "Cannot pin \(device.name) as DAC — choose a hardware output."
            return
        }
        pinnedDeviceUID = device?.uid
    }

    func isPinned(_ device: AudioOutputDevice) -> Bool {
        device.uid == pinnedDeviceUID
    }

    /// Menu action entry — returns immediately so MenuBarExtra dismissal cannot race AudioUnit teardown.
    func togglePassThrough() {
        passThroughOp?.cancel()
        passThroughOp = Task { @MainActor [weak self] in
            // Let the status-item menu finish dismissing before touching Core Audio.
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.isPassThroughEnabled {
                self.disablePassThrough(restoreDefault: true)
            } else {
                await self.enablePassThrough()
            }
        }
    }

    private func enablePassThrough() async {
        lastError = nil
        guard let virtual = deviceManager.preferredVirtualLoopback() else {
            lastError = PassThroughError.missingVirtualDevice.localizedDescription
            isPassThroughEnabled = false
            syncBridgeRunningFlag()
            updatePathStatus()
            return
        }
        guard let dac = pinnedDevice else {
            lastError = "Pin a hardware DAC before enabling Pass-through (do not use BlackHole as the destination)."
            isPassThroughEnabled = false
            syncBridgeRunningFlag()
            updatePathStatus()
            return
        }
        if VirtualDeviceCatalog.isVirtualLoopback(uid: dac.uid, name: dac.name) {
            lastError = "Pinned device is a virtual loopback. Pin a real DAC (e.g. DX5 II) first."
            isPassThroughEnabled = false
            syncBridgeRunningFlag()
            updatePathStatus()
            return
        }

        // Always re-query / request on toggle. Do not hard-abort solely on a stale API
        // “denied” while System Settings → Microphone is ON (common with ad-hoc re-signs).
        let micStatus = await MicrophoneAccess.ensureRequested()
        log.info("Pass-through mic check: \(MicrophoneAccess.diagnosticSummary, privacy: .public)")
        if micStatus == .denied {
            // Still attempt the bridge once — Core Audio may succeed when Settings is Allowed
            // but AVAudioApplication lags. If open fails, map to a clear Settings hint below.
            log.warning("Mic APIs report denied; will still try opening BlackHole capture")
        }

        // Remember the current default unless we already stored one from a previous enable.
        if previousDefaultOutputUID == nil {
            let current = deviceManager.defaultOutputDevice()?.uid
            // Don't remember BlackHole as the "restore" target if we crashed mid-session.
            if let current, !VirtualDeviceCatalog.isVirtualLoopback(uid: current, name: deviceManager.device(uid: current)?.name ?? "") {
                previousDefaultOutputUID = current
                UserDefaults.standard.set(previousDefaultOutputUID, forKey: Self.previousDefaultKey)
            } else if let pinned = pinnedDeviceUID {
                previousDefaultOutputUID = pinned
                UserDefaults.standard.set(previousDefaultOutputUID, forKey: Self.previousDefaultKey)
            }
        }

        do {
            // Align SB before opening the graph.
            if let format = acceptedDetection?.format ?? detectedFormat ?? deviceFormat {
                _ = try? deviceManager.apply(format: format, to: dac.id)
                _ = try? deviceManager.apply(format: format, to: virtual.id)
            }

            try deviceManager.setDefaultOutputDevice(id: virtual.id)
            passThroughBridge.setEQGainDB(eqGainDB)

            // Bridge start/stop runs on its own serial queue (not the menu thread).
            try await Task.detached(priority: .userInitiated) { [passThroughBridge, virtual, dac] in
                try passThroughBridge.start(inputDeviceID: virtual.id, outputDeviceID: dac.id)
            }.value

            guard passThroughBridge.isRunning else {
                throw PassThroughError.engine("Bridge reported not running after start.")
            }

            isPassThroughEnabled = true
            isBridgeRunning = true
            lastError = nil
            log.info("Pass-through enabled → \(dac.name, privacy: .public)")
            refreshExclusiveLock()
            updatePathStatus()
            updateStatusTitle()
        } catch {
            passThroughBridge.stop()
            if let previous = previousDefaultOutputUID {
                try? deviceManager.setDefaultOutputDevice(uid: previous)
            } else if let pinned = pinnedDeviceUID {
                try? deviceManager.setDefaultOutputDevice(uid: pinned)
            }
            isPassThroughEnabled = false
            isBridgeRunning = false
            passThroughBridge.setEQGainDB(0)
            lastError = Self.formatPassThroughFailure(error)
            log.error("Pass-through failed: \(self.lastError ?? "", privacy: .public) mic=\(MicrophoneAccess.diagnosticSummary, privacy: .public)")
            updatePathStatus()
            updateStatusTitle()
        }
    }

    /// Prefer the real Core Audio / engine error. Only use the Microphone Settings blurb when
    /// capture looks like a TCC failure (invalid input format / explicit denial), not for DAC busy etc.
    private static func formatPassThroughFailure(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lowered = raw.lowercased()
        let looksLikeCaptureTCC =
            lowered.contains("invalid input format")
            || lowered.contains("0 hz")
            || lowered.contains("ch 0")
            || (lowered.contains("permission") || lowered.contains("not authorized"))
        if looksLikeCaptureTCC || MicrophoneAccess.shouldSurfaceDeniedHelp {
            // Keep the underlying detail so we never show a blanket deny when Settings is ON
            // but the real failure was something else — append diagnostics.
            if MicrophoneAccess.isGranted {
                return "\(raw) (Microphone is Allowed in Settings; \(MicrophoneAccess.diagnosticSummary))"
            }
            return "\(MicrophoneAccess.settingsHelp) [\(raw); \(MicrophoneAccess.diagnosticSummary)]"
        }
        return raw
    }

    private func disablePassThrough(restoreDefault: Bool) {
        // stop() is synchronous on the bridge serial queue — safe after the menu-dismiss delay.
        passThroughBridge.stop()
        passThroughBridge.setEQGainDB(0)
        isPassThroughEnabled = false
        isBridgeRunning = false
        lastError = nil
        if restoreDefault, let previous = previousDefaultOutputUID {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
            previousDefaultOutputUID = nil
            UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        }
        refreshExclusiveLock()
        updatePathStatus()
        updateStatusTitle()
        log.info("Pass-through disabled")
    }

    private func restartPassThroughBridge() async {
        guard isPassThroughEnabled else { return }
        guard let virtual = deviceManager.preferredVirtualLoopback() else {
            lastError = PassThroughError.missingVirtualDevice.localizedDescription
            disablePassThrough(restoreDefault: true)
            return
        }

        guard let output = resolveHardwareDAC() else {
            lastError = "Pin a real DAC for pass-through."
            disablePassThrough(restoreDefault: true)
            return
        }

        do {
            passThroughBridge.setEQGainDB(eqGainDB)
            try await Task.detached(priority: .userInitiated) { [passThroughBridge, virtual, output] in
                try passThroughBridge.start(inputDeviceID: virtual.id, outputDeviceID: output.id)
            }.value
            isBridgeRunning = passThroughBridge.isRunning
            lastError = isBridgeRunning ? nil : "Bridge failed to restart."
            if !isBridgeRunning {
                lastError = lastError ?? "Bridge failed to restart."
            }
        } catch {
            isBridgeRunning = false
            lastError = error.localizedDescription
            log.error("Bridge restart failed: \(error.localizedDescription, privacy: .public)")
        }
        updatePathStatus()
        updateStatusTitle()
    }

    /// After a crash, BlackHole may still be the system default with no bridge — restore previous output.
    private func recoverOrphanedPassThroughDefault() {
        guard let previous = previousDefaultOutputUID else { return }
        let current = deviceManager.defaultOutputDevice()
        if let current, VirtualDeviceCatalog.isVirtualLoopback(uid: current.uid, name: current.name) {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
            log.info("Restored default output after orphaned pass-through (\(previous, privacy: .public))")
        }
        previousDefaultOutputUID = nil
        UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        isPassThroughEnabled = false
        isBridgeRunning = false
    }

    private func syncBridgeRunningFlag() {
        let running = passThroughBridge.isRunning
        if isBridgeRunning != running {
            isBridgeRunning = running
            if isPassThroughEnabled && !running {
                lastError = lastError ?? "Pass-through bridge stopped unexpectedly."
            }
            updatePathStatus()
            updateStatusTitle()
        }
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
        if isPassThroughEnabled && isBridgeRunning {
            let dacName = pinnedDevice?.name ?? "DAC"
            let virtualName = deviceManager.preferredVirtualLoopback()?.name ?? "Virtual"
            let eqTag = isEQActive ? String(format: " · EQ %+.0f dB", eqGainDB) : " · EQ bypass"
            pathStatusText = "Virtual → DAC (\(virtualName) → \(dacName))\(eqTag)"
            testEQDisabledReason = ""
        } else if isPassThroughEnabled && !isBridgeRunning {
            pathStatusText = lastError.map { "Pass-through error: \($0)" } ?? "Pass-through error: bridge not running"
            testEQDisabledReason = "Bridge not running"
        } else if let error = lastError, isPassThroughFailure(error) {
            pathStatusText = "Pass-through error: \(error)"
            testEQDisabledReason = "Enable Pass-through first"
        } else if virtualDeviceAvailable {
            pathStatusText = "Matching only"
            testEQDisabledReason = "Enable Pass-through first"
        } else {
            pathStatusText = "Matching only (install BlackHole 2ch for pass-through)"
            testEQDisabledReason = "Install BlackHole 2ch, then enable Pass-through"
        }
    }

    private func isPassThroughFailure(_ error: String) -> Bool {
        let keys = [
            "pass-through", "blackhole", "input access", "microphone",
            "pin a hardware", "virtual", "bridge", "audio unit", "dac before"
        ]
        let lowered = error.lowercased()
        return keys.contains { lowered.contains($0) }
    }

    private func updateStatusTitle() {
        if isMatchingLocked {
            statusTitle = "Locked"
            return
        }
        if isPassThroughEnabled && isBridgeRunning {
            if isEQActive {
                statusTitle = String(format: "EQ %+.0f dB", eqGainDB)
            } else if let format = deviceFormat {
                statusTitle = "PT \(format.shortDescription)"
            } else {
                statusTitle = "PT On"
            }
            return
        }
        if isPassThroughEnabled {
            statusTitle = "PT Err"
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
