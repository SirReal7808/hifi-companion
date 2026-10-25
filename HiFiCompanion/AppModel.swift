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
    /// Serializes enable/disable so a second menu click cannot cancel mid-flight and leave
    /// BlackHole as default with a dead bridge (or audio + a stale red error).
    private var passThroughOp: Task<Void, Never>?
    private var passThroughBusy = false
    private var passThroughPendingTarget: Bool?

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

    /// Headless check: enable → assert BH default + bridge running + no denial string → disable → restore.
    func runPassThroughSmokeTest() async -> Int32 {
        refreshDevices()
        let beforeUID = deviceManager.defaultOutputDevice()?.uid
        print("SMOKE: pinned=\(pinnedDevice?.name ?? "nil") virtual=\(deviceManager.preferredVirtualLoopback()?.name ?? "nil")")
        print("SMOKE: mic \(MicrophoneAccess.diagnosticSummary)")
        print("SMOKE: default_before=\(deviceManager.defaultOutputDevice()?.name ?? "nil")")

        await applyPassThrough(enabled: true)

        let defaultNow = deviceManager.defaultOutputDevice()
        let defaultIsBH = defaultNow.map { VirtualDeviceCatalog.isVirtualLoopback(uid: $0.uid, name: $0.name) } ?? false
        let running = isBridgeRunning && passThroughBridge.isRunning && isPassThroughEnabled
        let err = lastError ?? ""
        let denial = err.localizedCaseInsensitiveContains("Input access denied")

        print("SMOKE: after_enable running=\(running) path=\(pathStatusText) default=\(defaultNow?.name ?? "nil") lastError=\(err.isEmpty ? "nil" : err)")

        var failed = false
        if !running {
            print("SMOKE: FAIL bridge not running / UI flags out of sync")
            failed = true
        }
        if !defaultIsBH {
            print("SMOKE: FAIL default output is not BlackHole")
            failed = true
        }
        if denial {
            print("SMOKE: FAIL false Input-access-denied string present")
            failed = true
        }
        if !pathStatusText.hasPrefix("Virtual → DAC") {
            print("SMOKE: FAIL path status not Virtual → DAC (got \(pathStatusText))")
            failed = true
        }

        try? await Task.sleep(nanoseconds: 800_000_000)
        await applyPassThrough(enabled: false)

        let after = deviceManager.defaultOutputDevice()
        let restoredOK: Bool = {
            guard let after else { return false }
            if let beforeUID { return after.uid == beforeUID }
            return !VirtualDeviceCatalog.isVirtualLoopback(uid: after.uid, name: after.name)
        }()
        print("SMOKE: after_disable default=\(after?.name ?? "nil") restoredOK=\(restoredOK) bridge=\(passThroughBridge.isRunning)")
        if !restoredOK || passThroughBridge.isRunning || isBridgeRunning {
            print("SMOKE: FAIL disable/restore")
            failed = true
        }

        if failed {
            // Best-effort leave the machine usable.
            disablePassThrough(restoreDefault: true)
            return 1
        }
        print("SMOKE: OK")
        return 0
    }

    func stop() {
        passThroughPendingTarget = nil
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

    /// Menu action — coalesced/serialized. Never cancel an in-flight enable (that left BH silent).
    func togglePassThrough() {
        // Prefer actual bridge state so a stuck “enabled” flag cannot require a kick click.
        let target = !passThroughBridge.isRunning
        passThroughOp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await self?.applyPassThrough(enabled: target)
        }
    }

    private func applyPassThrough(enabled: Bool) async {
        if passThroughBusy {
            passThroughPendingTarget = enabled
            return
        }
        passThroughBusy = true
        defer {
            passThroughBusy = false
            if let pending = passThroughPendingTarget {
                passThroughPendingTarget = nil
                Task { @MainActor in
                    await self.applyPassThrough(enabled: pending)
                }
            }
        }
        if enabled {
            await enablePassThrough()
        } else {
            disablePassThrough(restoreDefault: true)
        }
    }

    private func enablePassThrough() async {
        lastError = nil
        guard let virtual = deviceManager.preferredVirtualLoopback() else {
            lastError = PassThroughError.missingVirtualDevice.localizedDescription
            publishBridgeUI(running: false)
            return
        }
        guard let dac = pinnedDevice else {
            lastError = "Pin a hardware DAC before enabling Pass-through (do not use BlackHole as the destination)."
            publishBridgeUI(running: false)
            return
        }
        if VirtualDeviceCatalog.isVirtualLoopback(uid: dac.uid, name: dac.name) {
            lastError = "Pinned device is a virtual loopback. Pin a real DAC (e.g. DX5 II) first."
            publishBridgeUI(running: false)
            return
        }

        // Re-query on every enable; never hard-abort on stale API denied alone.
        let micStatus = await MicrophoneAccess.ensureRequested()
        log.info("Pass-through mic check: \(MicrophoneAccess.diagnosticSummary, privacy: .public)")
        if micStatus == .denied {
            log.warning("Mic APIs report denied; still trying BlackHole capture (Settings may already be On)")
        }

        // Remember restore target (never BlackHole).
        if previousDefaultOutputUID == nil {
            let current = deviceManager.defaultOutputDevice()
            if let current, !VirtualDeviceCatalog.isVirtualLoopback(uid: current.uid, name: current.name) {
                previousDefaultOutputUID = current.uid
                UserDefaults.standard.set(previousDefaultOutputUID, forKey: Self.previousDefaultKey)
            } else if let pinned = pinnedDeviceUID {
                previousDefaultOutputUID = pinned
                UserDefaults.standard.set(previousDefaultOutputUID, forKey: Self.previousDefaultKey)
            }
        }

        var didSwitchDefaultToVirtual = false
        do {
            if let format = acceptedDetection?.format ?? detectedFormat ?? deviceFormat {
                _ = try? deviceManager.apply(format: format, to: dac.id)
                _ = try? deviceManager.apply(format: format, to: virtual.id)
            }

            passThroughBridge.setEQGainDB(eqGainDB)

            // CRITICAL: start BlackHole→DAC bridge WHILE default is still the hardware DAC.
            // Switching default to BlackHole first reconfigures BH and made setCurrentDevice
            // return kAudioHardwareIllegalOperationError ('nope') on the first click.
            try await Task.detached(priority: .userInitiated) { [passThroughBridge, virtual, dac] in
                try passThroughBridge.start(inputDeviceID: virtual.id, outputDeviceID: dac.id)
            }.value

            guard passThroughBridge.isRunning else {
                throw PassThroughError.engine("Bridge reported not running after start.")
            }

            // Only now route apps into BlackHole.
            try deviceManager.setDefaultOutputDevice(id: virtual.id)
            didSwitchDefaultToVirtual = true

            lastError = nil
            publishBridgeUI(running: true)
            log.info("Pass-through enabled → \(dac.name, privacy: .public)")
            refreshExclusiveLock()
        } catch {
            passThroughBridge.stop()
            if didSwitchDefaultToVirtual {
                restorePreviousDefaultOutput()
            }
            passThroughBridge.setEQGainDB(0)
            lastError = Self.formatPassThroughFailure(error)
            publishBridgeUI(running: false)
            log.error("Pass-through failed: \(self.lastError ?? "", privacy: .public) mic=\(MicrophoneAccess.diagnosticSummary, privacy: .public)")
        }
    }

    /// Real Core Audio / engine errors stay visible. “Input access denied” only when capture
    /// format is empty / unauthorized — never for 'nope' illegal-operation / device-busy.
    private static func formatPassThroughFailure(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lowered = raw.lowercased()

        if lowered.contains("'nope'") || lowered.contains("illegaloperation") {
            return raw // device reconfigure / busy — not TCC
        }
        if lowered.contains("audio unit error") {
            return "\(raw) [\(MicrophoneAccess.diagnosticSummary)]"
        }

        let looksLikeEmptyCapture =
            lowered.contains("invalid input format")
            || (lowered.contains("rate 0") && lowered.contains("ch 0"))
            || lowered.contains("not authorized")
        if looksLikeEmptyCapture && !MicrophoneAccess.isGranted {
            return "\(MicrophoneAccess.settingsHelp) [\(raw); \(MicrophoneAccess.diagnosticSummary)]"
        }
        if looksLikeEmptyCapture && MicrophoneAccess.isGranted {
            return "\(raw) (Microphone Allowed in Settings; \(MicrophoneAccess.diagnosticSummary))"
        }
        return raw
    }

    private func restorePreviousDefaultOutput() {
        if let previous = previousDefaultOutputUID {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
        } else if let pinned = pinnedDeviceUID {
            try? deviceManager.setDefaultOutputDevice(uid: pinned)
        }
    }

    private func publishBridgeUI(running: Bool) {
        isBridgeRunning = running
        isPassThroughEnabled = running
        if running {
            lastError = nil
        }
        updatePathStatus()
        updateStatusTitle()
    }

    private func disablePassThrough(restoreDefault: Bool) {
        passThroughBridge.stop()
        passThroughBridge.setEQGainDB(0)
        if restoreDefault {
            restorePreviousDefaultOutput()
            previousDefaultOutputUID = nil
            UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        }
        lastError = nil
        publishBridgeUI(running: false)
        refreshExclusiveLock()
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
            if passThroughBridge.isRunning {
                lastError = nil
                publishBridgeUI(running: true)
            } else {
                lastError = "Bridge failed to restart."
                publishBridgeUI(running: false)
            }
        } catch {
            lastError = Self.formatPassThroughFailure(error)
            publishBridgeUI(running: false)
            log.error("Bridge restart failed: \(self.lastError ?? "", privacy: .public)")
        }
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
        if isBridgeRunning != running || isPassThroughEnabled != running {
            if running {
                // Bridge is live — UI must match (clears stale red errors from a raced toggle).
                publishBridgeUI(running: true)
            } else if isPassThroughEnabled {
                lastError = lastError ?? "Pass-through bridge stopped unexpectedly."
                publishBridgeUI(running: false)
            } else {
                isBridgeRunning = false
                updatePathStatus()
                updateStatusTitle()
            }
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
