import Combine
import CoreAudio
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
            Task { await applyAcceptedDetectionIfNeeded(force: true) }
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
    /// True only while the process-tap → DAC bridge is actually running.
    @Published private(set) var isBridgeRunning = false
    @Published private(set) var pathStatusText = "Matching only"
    /// Capture meter line while pass-through is running (tap RMS from other apps).
    @Published private(set) var signalMeterText = ""
    @Published private(set) var isHearingAudio = false
    /// 10-band PEQ (live only while Pass-through is on).
    @Published private(set) var peqBands: [EQBand] = EQBand.defaultTenBands()
    @Published private(set) var peqOutputGainDB: Double = 0
    @Published private(set) var peqBypass = false
    /// Auto-lower output gain to the safe ceiling after band edits (never raise).
    @Published private(set) var peqAutoOutputGain = true
    /// When bypassing bands, still apply output gain for loudness-matched A/B.
    @Published private(set) var peqBypassGainMatch = true
    @Published private(set) var peqPeakBoostDB: Double = 0
    @Published private(set) var peqClippingWarning = false
    /// Short reason when PEQ panel controls are disabled.
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
    /// One-shot launch cleanup if an older build left a virtual device as the system default.
    private var previousDefaultOutputUID: String?
    private var previousDefaultInputUID: String?
    /// Serializes enable/disable so a second menu click cannot race mid-flight.
    private var passThroughOp: Task<Void, Never>?
    private var passThroughBusy = false
    private var passThroughPendingTarget: Bool?
    /// Serializes tap-graph rebuilds after SB / rate changes (avoids overlapping tear-downs).
    private var formatRebuildTask: Task<Void, Never>?
    private var formatRebuildGeneration: UInt64 = 0
    /// True while tap graph is intentionally stopped for an SB rebuild (poll must not clear PT).
    private var isPassThroughRebuilding = false

    private static let pinnedDeviceKey = "pinnedOutputDeviceUID"
    private static let previousDefaultKey = "passThroughPreviousDefaultUID"
    private static let previousDefaultInputKey = "passThroughPreviousDefaultInputUID"
    private static let peqBandsKey = "peqBandsJSON"
    private static let peqOutputGainKey = "peqOutputGainDB"
    private static let peqBypassKey = "peqBypass"
    private static let peqAutoOutputGainKey = "peqAutoOutputGain"
    private static let peqBypassGainMatchKey = "peqBypassGainMatch"
    private static let peqClippingWarningKey = "peqClippingWarning"

    /// Shown in the menu under matching status.
    static let appleMusicModeMenuNote =
        "Apple Music mode switches only while Music is the only app using this device."

    static let passThroughMenuNote =
        "Pass-through: Core Audio process tap of other apps → pinned DAC (leave Music playing on the DAC)."

    /// EQ is “active” when PT is running, bands are not bypassed, and at least one band colors the signal.
    var isEQActive: Bool { isBridgeRunning && passThroughBridge.isEQColoring }

    var peqSafeCeilingDB: Double {
        PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: peqPeakBoostDB)
    }

    var eqStatusText: String {
        guard isBridgeRunning else {
            return "EQ: off (matching-only is dry)"
        }
        if peqBypass {
            if peqBypassGainMatch {
                return String(format: "EQ: bypassed · out %+.1f dB (bands skipped)", peqOutputGainDB)
            }
            return "EQ: bypassed · true dry (unity)"
        }
        if isEQActive {
            return String(
                format: "EQ: active · out %+.1f dB · peak +%.1f (not bit-perfect)",
                peqOutputGainDB,
                peqPeakBoostDB
            )
        }
        return String(format: "EQ: flat · out %+.1f dB", peqOutputGainDB)
    }

    private init() {
        pinnedDeviceUID = UserDefaults.standard.string(forKey: Self.pinnedDeviceKey)
        previousDefaultOutputUID = UserDefaults.standard.string(forKey: Self.previousDefaultKey)
        previousDefaultInputUID = UserDefaults.standard.string(forKey: Self.previousDefaultInputKey)
        loadPEQFromDefaults()
        pushPEQToBridge()
    }

    /// Opens the floating 10-band PEQ panel.
    func showPEQPanel() {
        PEQPanelController.shared.show()
    }

    /// Legacy name used by menu / automation.
    func showTestEQPanel() { showPEQPanel() }

    func setPEQBypass(_ bypass: Bool) {
        peqBypass = bypass
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    func setPEQBypassGainMatch(_ match: Bool) {
        peqBypassGainMatch = match
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    func setPEQAutoOutputGain(_ auto: Bool) {
        peqAutoOutputGain = auto
        if auto {
            applyBandChangeHeadroom()
        }
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    func setPEQOutputGainDB(_ gainDB: Double) {
        let result = PEQHeadroom.applyManualOutputGain(
            requested: gainDB,
            bands: peqBands,
            sampleRate: peqSampleRateForHeadroom()
        )
        peqOutputGainDB = result.outputGainDB
        peqPeakBoostDB = result.peakBoostDB
        peqClippingWarning = result.clippingWarning
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    /// Snap output gain to the current safe ceiling without turning Auto on.
    func setPEQOutputGainToSafe() {
        let result = PEQHeadroom.applySetSafe(
            bands: peqBands,
            sampleRate: peqSampleRateForHeadroom()
        )
        peqOutputGainDB = result.outputGainDB
        peqPeakBoostDB = result.peakBoostDB
        peqClippingWarning = result.clippingWarning
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    func updatePEQBand(id: UUID, mutate: (inout EQBand) -> Void) {
        guard let index = peqBands.firstIndex(where: { $0.id == id }) else { return }
        var band = peqBands[index]
        mutate(&band)
        band.clamp()
        peqBands[index] = band
        applyBandChangeHeadroom()
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    /// Reset band gains/freqs/Q to defaults. Does not change output gain.
    func resetPEQFlat() {
        let result = PEQHeadroom.applyResetBands(
            outputGainDB: peqOutputGainDB,
            sampleRate: peqSampleRateForHeadroom()
        )
        peqBands = result.bands
        peqOutputGainDB = result.outputGainDB
        peqPeakBoostDB = result.peakBoostDB
        peqClippingWarning = result.clippingWarning
        persistPEQ()
        pushPEQToBridge()
        updatePathStatus()
        updateStatusTitle()
    }

    private func applyBandChangeHeadroom() {
        let result = PEQHeadroom.applyBandChange(
            bands: peqBands,
            outputGainDB: peqOutputGainDB,
            sampleRate: peqSampleRateForHeadroom(),
            autoOutputGain: peqAutoOutputGain
        )
        peqOutputGainDB = result.outputGainDB
        peqPeakBoostDB = result.peakBoostDB
        peqClippingWarning = result.clippingWarning
    }

    private func peqSampleRateForHeadroom() -> Double {
        let live = passThroughBridge.graphSampleRate
        if live > 0 { return live }
        return deviceFormat?.sampleRate ?? 48_000
    }

    private func pushPEQToBridge() {
        passThroughBridge.applyPEQ(
            bands: peqBands,
            outputGainDB: peqOutputGainDB,
            bypass: peqBypass,
            applyOutputGainWhenBypassed: peqBypassGainMatch
        )
    }

    private func loadPEQFromDefaults() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.peqBandsKey),
           let decoded = try? JSONDecoder().decode([EQBand].self, from: data),
           decoded.count == PEQProcessor.bandCount {
            peqBands = decoded.map { band in
                var b = band
                b.clamp()
                return b
            }
        } else {
            peqBands = EQBand.defaultTenBands()
        }
        peqOutputGainDB = defaults.object(forKey: Self.peqOutputGainKey) as? Double ?? 0
        peqBypass = defaults.bool(forKey: Self.peqBypassKey)
        peqAutoOutputGain = defaults.object(forKey: Self.peqAutoOutputGainKey) as? Bool ?? true
        peqBypassGainMatch = defaults.object(forKey: Self.peqBypassGainMatchKey) as? Bool ?? true
        let storedWarning = defaults.bool(forKey: Self.peqClippingWarningKey)
        peqPeakBoostDB = PEQHeadroom.peakBoostDB(bands: peqBands, sampleRate: 48_000)
        let risk = PEQHeadroom.isClippingRisk(
            outputGainDB: peqOutputGainDB,
            peakBoostDB: peqPeakBoostDB
        )
        // Keep a persisted warning across relaunch while still at risk; clear once safe.
        peqClippingWarning = risk
        _ = storedWarning
    }

    private func persistPEQ() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(peqBands) {
            defaults.set(data, forKey: Self.peqBandsKey)
        }
        defaults.set(peqOutputGainDB, forKey: Self.peqOutputGainKey)
        defaults.set(peqBypass, forKey: Self.peqBypassKey)
        defaults.set(peqAutoOutputGain, forKey: Self.peqAutoOutputGainKey)
        defaults.set(peqBypassGainMatch, forKey: Self.peqBypassGainMatchKey)
        defaults.set(peqClippingWarning, forKey: Self.peqClippingWarningKey)
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
                self?.refreshSignalMeter()
                self?.reconcilePassThroughFormatIfNeeded()
            }
        }
    }

    /// Headless check: play into DAC first → enable process-tap PT (default stays DAC) → tap RMS → disable.
    /// Does **not** treat Test tone as Signal success.
    func runPassThroughSmokeTest() async -> Int32 {
        refreshDevices()
        let beforeUID = deviceManager.defaultOutputDevice()?.uid
        let dac = pinnedDevice
        let dacID = dac?.id
        print("SMOKE: pinned=\(dac?.name ?? "nil") path=process-tap")
        print("SMOKE: default_before=\(deviceManager.defaultOutputDevice()?.name ?? "nil")")

        guard let dac else {
            print("SMOKE: FAIL no pinned DAC")
            return 1
        }

        // Keep system default on the pinned DAC (process tap targets that device).
        if deviceManager.defaultOutputDevice()?.uid != dac.uid {
            try? deviceManager.setDefaultOutputDevice(uid: dac.uid)
            print("SMOKE: set default output → \(dac.name)")
        }

        // Start sibling playback **before** PT so it mirrors Music-already-playing-on-DAC.
        let tonePath = "/tmp/hifi_tone8s.wav"
        if !FileManager.default.fileExists(atPath: tonePath) {
            // Minimal 8s stereo 16-bit WAV (no AVAudioFile interleaved quirks).
            let sampleRate = 44_100
            let seconds = 8
            let channels = 2
            let dataSize = sampleRate * seconds * channels * 2
            var data = Data(count: 44 + dataSize)
            data.replaceSubrange(0..<4, with: Array("RIFF".utf8))
            data.replaceSubrange(8..<12, with: Array("WAVE".utf8))
            data.replaceSubrange(12..<16, with: Array("fmt ".utf8))
            func putU32(_ offset: Int, _ value: UInt32) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
            }
            func putU16(_ offset: Int, _ value: UInt16) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { data.replaceSubrange(offset..<(offset + 2), with: $0) }
            }
            putU32(4, UInt32(36 + dataSize))
            putU32(16, 16) // PCM fmt chunk size
            putU16(20, 1) // PCM
            putU16(22, UInt16(channels))
            putU32(24, UInt32(sampleRate))
            putU32(28, UInt32(sampleRate * channels * 2))
            putU16(32, UInt16(channels * 2))
            putU16(34, 16)
            data.replaceSubrange(36..<40, with: Array("data".utf8))
            putU32(40, UInt32(dataSize))
            let twoPiF = 2.0 * Double.pi * 440.0 / Double(sampleRate)
            for i in 0..<(sampleRate * seconds) {
                let sample = Int16((0.2 * 32767.0 * sin(twoPiF * Double(i))).rounded())
                var le = sample.littleEndian
                let base = 44 + i * 4
                withUnsafeBytes(of: &le) { bytes in
                    data.replaceSubrange(base..<(base + 2), with: bytes)
                    data.replaceSubrange((base + 2)..<(base + 4), with: bytes)
                }
            }
            do {
                try data.write(to: URL(fileURLWithPath: tonePath))
            } catch {
                print("SMOKE: FAIL write tone wav \(error.localizedDescription)")
                return 1
            }
        }
        let prePlay = Process()
        prePlay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        prePlay.arguments = ["-v", "1", tonePath]
        do {
            try prePlay.run()
            print("SMOKE: pre-PT afplay started (pid=\(prePlay.processIdentifier))")
            try? await Task.sleep(nanoseconds: 250_000_000)
        } catch {
            print("SMOKE: FAIL pre-PT afplay \(error.localizedDescription)")
            return 1
        }

        await applyPassThrough(enabled: true)

        let defaultNow = deviceManager.defaultOutputDevice()
        let defaultIsVirtual = defaultNow.map { VirtualDeviceCatalog.isVirtualLoopback(uid: $0.uid, name: $0.name) } ?? false
        let running = isBridgeRunning && passThroughBridge.isRunning && isPassThroughEnabled
        let err = lastError ?? ""
        let meter = passThroughBridge.currentMeter()

        print("SMOKE: after_enable running=\(running) path=\(pathStatusText) default=\(defaultNow?.name ?? "nil") lastError=\(err.isEmpty ? "nil" : err)")
        print("SMOKE: out=\(meter.outputDeviceID) wantDAC=\(dacID.map(String.init) ?? "?") rate=\(meter.sampleRate) cb=\(meter.captureCallbacks)")

        var failed = false
        if !running {
            print("SMOKE: FAIL bridge not running / UI flags out of sync")
            failed = true
        }
        if defaultIsVirtual {
            print("SMOKE: FAIL default output was switched to a virtual device (must stay on DAC)")
            failed = true
        }
        if let beforeUID, let defaultNow, defaultNow.uid != beforeUID && defaultNow.uid != dac.uid {
            print("SMOKE: FAIL default output changed unexpectedly")
            failed = true
        }
        if err.localizedCaseInsensitiveContains("Input access denied") {
            print("SMOKE: FAIL false Microphone Input-denied string present")
            failed = true
        }
        if !pathStatusText.hasPrefix("Process tap → DAC") {
            print("SMOKE: FAIL path status not Process tap → DAC (got \(pathStatusText))")
            failed = true
        }
        let menuBlob = [
            pathStatusText, matchingStatusText, eqStatusText, signalMeterText,
            AppModel.passThroughMenuNote, AppModel.appleMusicModeMenuNote, lastError ?? ""
        ].joined(separator: "\n")
        if menuBlob.localizedCaseInsensitiveContains("blackhole") || menuBlob.localizedCaseInsensitiveContains("black hole") {
            print("SMOKE: FAIL BlackHole string still present in menu/status copy")
            failed = true
        }
        if let dacID, meter.outputDeviceID != dacID {
            print("SMOKE: FAIL playback device \(meter.outputDeviceID) is not pinned DAC \(dacID)")
            failed = true
        }

        if running {
            // Tap RMS from pre-started afplay (Music-like). Never claim success from inject tone.
            var tapPeak: Float = 0
            let deadline = Date().addingTimeInterval(2.5)
            while Date() < deadline {
                let m = passThroughBridge.currentMeter()
                tapPeak = max(tapPeak, m.capturePeakRMS)
                if tapPeak >= 0.004 { break }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            print("SMOKE: process-tap peakRMS=\(tapPeak) hearing=\(tapPeak >= 0.004) prePlayRunning=\(prePlay.isRunning)")
            if tapPeak < 0.004 {
                print("SMOKE: FAIL process tap silent while sibling audio was already playing on DAC")
                failed = true
            }

            // Tone must be audible on DAC mix but must NOT inflate Signal meter alone.
            let beforeTone = passThroughBridge.currentMeter().capturePeakRMS
            do {
                try passThroughBridge.playTestToneToDAC()
                print("SMOKE: DAC test tone mixed (Signal meter must stay tap-based)")
            } catch {
                print("SMOKE: FAIL DAC test tone \(error.localizedDescription)")
                failed = true
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
            let afterTone = passThroughBridge.currentMeter()
            print("SMOKE: meter beforeTone=\(beforeTone) afterTone=\(afterTone.capturePeakRMS) (tone is output-only)")
        }

        if prePlay.isRunning {
            prePlay.terminate()
            prePlay.waitUntilExit()
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        await applyPassThrough(enabled: false)

        let after = deviceManager.defaultOutputDevice()
        let defaultOK: Bool = {
            guard let after else { return false }
            return !VirtualDeviceCatalog.isVirtualLoopback(uid: after.uid, name: after.name)
        }()
        print("SMOKE: after_disable default=\(after?.name ?? "nil") defaultOK=\(defaultOK) bridge=\(passThroughBridge.isRunning)")
        if !defaultOK || passThroughBridge.isRunning || isBridgeRunning {
            print("SMOKE: FAIL disable (bridge still running or default is virtual)")
            failed = true
        }

        if failed {
            disablePassThrough(restoreDefault: true)
            return 1
        }
        print("SMOKE: OK")
        return 0
    }

    func playTestToneToDAC() {
        guard isBridgeRunning else {
            lastError = "Enable Pass-through first for Test tone to DAC."
            updatePathStatus()
            return
        }
        do {
            try passThroughBridge.playTestToneToDAC()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        updatePathStatus()
    }

    /// Automation entry points used by `--hold-passthrough-seconds` / smoke helpers.
    func applyPassThroughForAutomation(enabled: Bool) async {
        await applyPassThrough(enabled: enabled)
    }

    func bridgeMeterForAutomation() -> PassThroughMeter {
        refreshSignalMeter()
        return passThroughBridge.currentMeter()
    }

    func graphSampleRateForAutomation() -> Double {
        passThroughBridge.graphSampleRate
    }

    func setEQGainForAutomation(_ gainDB: Double) {
        // Map legacy single-band smoke onto the 1 kHz PEQ band.
        if let band = peqBands.first(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            updatePEQBand(id: band.id) { $0.gainDB = gainDB; $0.enabled = true }
        }
        setPEQBypass(false)
    }

    /// Force a DAC rate change while PT is on and wait for the tap graph to rebuild.
    func forceDACRateChangeForAutomation(sampleRate: Double, bitDepth: Int = 24) async -> Bool {
        guard let dac = resolveHardwareDAC() else { return false }
        let format = AudioFormatInfo(sampleRate: sampleRate, bitDepth: bitDepth)
        let wasPT = isPassThroughEnabled
        if wasPT && passThroughBridge.isRunning {
            formatRebuildGeneration &+= 1
            isPassThroughRebuilding = true
            passThroughBridge.stop()
            publishBridgeUI(running: false, clearingEnabled: false)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        do {
            let applied = try deviceManager.apply(format: format, to: dac.id)
            deviceFormat = applied
            if wasPT {
                await waitForDACFormat(applied, on: dac.id, timeoutSeconds: 1.5)
                await rebuildPassThroughGraph(reason: "automation-rate")
            }
            let graph = passThroughBridge.graphSampleRate
            let ok = passThroughBridge.isRunning && abs(graph - applied.sampleRate) < 1.0
            print("RATE_REBUILD: dac=\(applied.sampleRate) graph=\(graph) running=\(passThroughBridge.isRunning) ok=\(ok) lastError=\(lastError ?? "nil")")
            return ok
        } catch {
            isPassThroughRebuilding = false
            print("RATE_REBUILD: FAIL \(error.localizedDescription)")
            return false
        }
    }

    /// Prove PEQ is live on the process-tap path (not a dead engine).
    func proveTestEQLiveForAutomation(gainDB: Double = 9) -> Bool {
        setEQGainForAutomation(gainDB)
        guard isBridgeRunning, isEQActive, !passThroughBridge.isEQBypassed else {
            print("EQ_PROOF: FAIL not active on live bridge (running=\(isBridgeRunning) active=\(isEQActive) bypassed=\(passThroughBridge.isEQBypassed))")
            return false
        }
        let boost = passThroughBridge.peqPeakBoostDB()
        let at1k = PEQHeadroom.peakBoostDB(bands: peqBands, sampleRate: peqSampleRateForHeadroom())
        let ok = boost > gainDB - 3.0 && at1k > gainDB - 3.0
        print("EQ_PROOF: bandGain=\(gainDB) peakBoost=\(boost) status=\(eqStatusText) ok=\(ok)")
        setEQGainForAutomation(0)
        return ok
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

    /// Menu action — coalesced/serialized.
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
        guard let dac = pinnedDevice else {
            lastError = "Pin a hardware DAC before enabling Pass-through."
            publishBridgeUI(running: false)
            return
        }
        if VirtualDeviceCatalog.isVirtualLoopback(uid: dac.uid, name: dac.name) {
            lastError = "Pinned device is a virtual loopback. Pin a real DAC (e.g. DX5 II) first."
            publishBridgeUI(running: false)
            return
        }

        // Keep system default on the real DAC — process tap captures apps already playing there.
        do {
            if let format = acceptedDetection?.format ?? detectedFormat ?? deviceFormat {
                _ = try? deviceManager.apply(format: format, to: dac.id)
            }

            pushPEQToBridge()

            try await Task.detached(priority: .userInitiated) { [passThroughBridge, dac] in
                try passThroughBridge.start(outputDeviceID: dac.id, outputDeviceUID: dac.uid)
            }.value

            guard passThroughBridge.isRunning else {
                throw PassThroughError.engine("Bridge reported not running after start.")
            }

            // Re-apply after start so sections match the live tap sample rate.
            pushPEQToBridge()

            let meter = passThroughBridge.currentMeter()
            guard meter.outputDeviceID == dac.id else {
                throw PassThroughError.engine(
                    "Playback device is \(meter.outputDeviceID), not pinned DAC \(dac.id) (\(dac.name))."
                )
            }

            lastError = nil
            publishBridgeUI(running: true)
            refreshSignalMeter()
            log.info("Process-tap Pass-through enabled → \(dac.name, privacy: .public)")
            refreshExclusiveLock()
        } catch {
            passThroughBridge.stop()
            lastError = Self.formatPassThroughFailure(error)
            publishBridgeUI(running: false)
            log.error("Pass-through failed: \(self.lastError ?? "", privacy: .public)")
        }
    }

    private static func formatPassThroughFailure(_ error: Error) -> String {
        error.localizedDescription
    }

    private func restorePreviousDefaultOutput() {
        // Process-tap PT never changes the system default. Clear any leftover keys from older builds.
        if let previous = previousDefaultOutputUID {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
        }
        if let previousIn = previousDefaultInputUID {
            try? deviceManager.setDefaultInputDevice(uid: previousIn)
        }
        previousDefaultOutputUID = nil
        previousDefaultInputUID = nil
        UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        UserDefaults.standard.removeObject(forKey: Self.previousDefaultInputKey)
    }

    private func publishBridgeUI(running: Bool, clearingEnabled: Bool = true) {
        isBridgeRunning = running
        if running {
            isPassThroughEnabled = true
            lastError = nil
        } else if clearingEnabled {
            isPassThroughEnabled = false
            signalMeterText = ""
            isHearingAudio = false
        } else {
            // Mid-rebuild: keep Pass-through “on” while the tap graph is torn down briefly.
            signalMeterText = "Signal: rebuilding for new sample rate…"
            isHearingAudio = false
        }
        updatePathStatus()
        updateStatusTitle()
    }

    private func refreshSignalMeter() {
        guard isBridgeRunning else {
            if !signalMeterText.isEmpty {
                signalMeterText = ""
                isHearingAudio = false
            }
            return
        }
        _ = passThroughBridge.ensureDeviceBinding()
        let meter = passThroughBridge.currentMeter()
        signalMeterText = meter.menuLine
        isHearingAudio = meter.isHearingAudio
        // If playback drifted off the DAC, surface it — do not stay silently wrong.
        if let dac = pinnedDevice, meter.outputDeviceID != kAudioObjectUnknown, meter.outputDeviceID != dac.id {
            lastError = "Playback drifted to device \(meter.outputDeviceID) (want DAC \(dac.id)). Disable and re-enable Pass-through."
            updatePathStatus()
        }
    }

    private func disablePassThrough(restoreDefault: Bool) {
        passThroughBridge.stop()
        if restoreDefault {
            restorePreviousDefaultOutput()
            previousDefaultOutputUID = nil
            previousDefaultInputUID = nil
            UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
            UserDefaults.standard.removeObject(forKey: Self.previousDefaultInputKey)
        }
        lastError = nil
        publishBridgeUI(running: false)
        refreshExclusiveLock()
        log.info("Pass-through disabled")
    }

    private func restartPassThroughBridge() async {
        await rebuildPassThroughGraph(reason: "restart")
    }

    /// Tear down tap+aggregate and rebuild at the DAC’s current rate (keeps EQ gain).
    private func rebuildPassThroughGraph(reason: String) async {
        guard isPassThroughEnabled else { return }
        guard let output = resolveHardwareDAC() else {
            lastError = "Pin a real DAC for pass-through."
            disablePassThrough(restoreDefault: true)
            return
        }

        formatRebuildGeneration &+= 1
        let generation = formatRebuildGeneration
        isPassThroughRebuilding = true
        defer {
            if generation == formatRebuildGeneration {
                isPassThroughRebuilding = false
            }
        }
        // Stop first so we never keep pushing old-rate buffers into the new device format,
        // and so apply/settle can claim the DAC without fighting the aggregate.
        passThroughBridge.stop()
        publishBridgeUI(running: false, clearingEnabled: false)

        // Let Core Audio release the device before we reopen at the new rate.
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard generation == formatRebuildGeneration, isPassThroughEnabled else { return }

        if let expected = deviceManager.currentFormat(for: output.id) {
            await waitForDACFormat(expected, on: output.id, timeoutSeconds: 1.2)
        }
        guard generation == formatRebuildGeneration, isPassThroughEnabled else { return }

        do {
            pushPEQToBridge()
            try await Task.detached(priority: .userInitiated) { [passThroughBridge, output] in
                try passThroughBridge.start(outputDeviceID: output.id, outputDeviceUID: output.uid)
            }.value
            guard generation == formatRebuildGeneration else { return }
            if passThroughBridge.isRunning {
                pushPEQToBridge()
                lastError = nil
                publishBridgeUI(running: true)
                let graphHz = passThroughBridge.graphSampleRate
                let dacHz = deviceManager.currentFormat(for: output.id)?.sampleRate ?? 0
                print("REBUILD_OK reason=\(reason) graph=\(graphHz) dac=\(dacHz) outGain=\(peqOutputGainDB)")
                log.info("Pass-through rebuilt (\(reason, privacy: .public)) graph=\(graphHz, privacy: .public)Hz dac=\(dacHz, privacy: .public)Hz out=\(self.peqOutputGainDB, privacy: .public)dB")
            } else {
                lastError = "Bridge failed to rebuild after sample-rate change."
                publishBridgeUI(running: false, clearingEnabled: false)
                print("REBUILD_FAIL reason=\(reason) not running after start")
            }
        } catch {
            guard generation == formatRebuildGeneration else {
                print("REBUILD_SKIP reason=\(reason) superseded")
                return
            }
            lastError = Self.formatPassThroughFailure(error)
            publishBridgeUI(running: false, clearingEnabled: false)
            print("REBUILD_FAIL reason=\(reason) error=\(lastError ?? "")")
            log.error("Bridge rebuild failed: \(self.lastError ?? "", privacy: .public)")
        }
    }

    /// If the DAC rate moved under a live tap graph, rebuild (handles SB changes that
    /// finished after the first restart, or external rate changes).
    private func reconcilePassThroughFormatIfNeeded() {
        guard isPassThroughEnabled, passThroughBridge.isRunning else { return }
        guard let dac = resolveHardwareDAC(),
              let dacFormat = deviceManager.currentFormat(for: dac.id)
        else { return }
        guard passThroughBridge.graphMismatchesDAC(sampleRate: dacFormat.sampleRate) else { return }
        log.info("DAC rate \(dacFormat.sampleRate, privacy: .public) ≠ graph \(self.passThroughBridge.graphSampleRate, privacy: .public) — scheduling rebuild")
        schedulePassThroughRebuild(reason: "dac-rate-drift")
    }

    private func schedulePassThroughRebuild(reason: String) {
        formatRebuildTask?.cancel()
        formatRebuildTask = Task { @MainActor [weak self] in
            // Debounce rapid SB hops (album with several rate changes).
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await self?.rebuildPassThroughGraph(reason: reason)
        }
    }

    private func waitForDACFormat(
        _ expected: AudioFormatInfo,
        on deviceID: AudioDeviceID,
        timeoutSeconds: Double
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let current = deviceManager.currentFormat(for: deviceID),
               abs(current.sampleRate - expected.sampleRate) < 1.0 {
                return
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// After a crash of an older build, a virtual device may still be the system default — restore hardware.
    private func recoverOrphanedPassThroughDefault() {
        let current = deviceManager.defaultOutputDevice()
        if let previous = previousDefaultOutputUID,
           let current,
           VirtualDeviceCatalog.isVirtualLoopback(uid: current.uid, name: current.name) {
            try? deviceManager.setDefaultOutputDevice(uid: previous)
            log.info("Restored default output after orphaned pass-through (\(previous, privacy: .public))")
        }
        if let previousIn = previousDefaultInputUID {
            try? deviceManager.setDefaultInputDevice(uid: previousIn)
        }
        previousDefaultOutputUID = nil
        previousDefaultInputUID = nil
        UserDefaults.standard.removeObject(forKey: Self.previousDefaultKey)
        UserDefaults.standard.removeObject(forKey: Self.previousDefaultInputKey)
        isPassThroughEnabled = false
        isBridgeRunning = false
    }

    private func syncBridgeRunningFlag() {
        let running = passThroughBridge.isRunning
        if isPassThroughRebuilding {
            // Intentional tear-down for sample-rate rebuild — do not clear enabled or raise error.
            if isBridgeRunning != running {
                isBridgeRunning = running
                updatePathStatus()
                updateStatusTitle()
            }
            return
        }
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
            Task { await applyAcceptedDetectionIfNeeded(force: false) }
        }
        updateStatusTitle()
    }

    /// Device where Music (and other apps) render when matching lock is evaluated.
    /// Process-tap Pass-through keeps apps on the real DAC (muted while tapped).
    private func musicFacingDevice() -> AudioOutputDevice? {
        pinnedDevice ?? deviceManager.defaultOutputDevice()
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
            Task { await applyAcceptedDetectionIfNeeded(force: true) }
            updateStatusTitle()
        case .unchanged:
            if wasLocked != isMatchingLocked {
                updateStatusTitle()
            }
        }
    }

    private func applyAcceptedDetectionIfNeeded(force: Bool) async {
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
            let wasPT = isPassThroughEnabled && passThroughBridge.isRunning
            // Release the tap aggregate before changing the DAC physical format so we
            // never keep an old-rate IOProc running into a reclocked device (crackle).
            if wasPT {
                formatRebuildGeneration &+= 1
                isPassThroughRebuilding = true
                passThroughBridge.stop()
                publishBridgeUI(running: false, clearingEnabled: false)
                try? await Task.sleep(nanoseconds: 60_000_000)
            }

            let applied = try deviceManager.apply(
                format: detection.format,
                to: dacTarget.id
            )
            switchGate.didApply(detection, previouslyApplied: previous)
            deviceFormat = applied
            lastError = nil

            if wasPT || isPassThroughEnabled {
                await waitForDACFormat(applied, on: dacTarget.id, timeoutSeconds: 1.2)
                await rebuildPassThroughGraph(reason: "sb-match")
            }
            updateStatusTitle()
        } catch {
            isPassThroughRebuilding = false
            lastError = error.localizedDescription
            if isPassThroughEnabled, !passThroughBridge.isRunning {
                schedulePassThroughRebuild(reason: "sb-match-recovery")
            }
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
            let eqTag: String = {
                if peqBypass { return String(format: " · EQ bypass · out %+.0f dB", peqOutputGainDB) }
                if isEQActive { return String(format: " · EQ · out %+.0f dB", peqOutputGainDB) }
                return String(format: " · EQ flat · out %+.0f dB", peqOutputGainDB)
            }()
            pathStatusText = "Process tap → DAC (\(dacName))\(eqTag)"
            testEQDisabledReason = ""
        } else if isPassThroughEnabled && !isBridgeRunning {
            if lastError == nil {
                pathStatusText = "Process tap rebuilding…"
                testEQDisabledReason = "Rebuilding after sample-rate change"
            } else {
                pathStatusText = "Pass-through error: \(lastError!)"
                testEQDisabledReason = "Bridge not running"
            }
        } else if let error = lastError, isPassThroughFailure(error) {
            pathStatusText = "Pass-through error: \(error)"
            testEQDisabledReason = "Enable Pass-through first"
        } else {
            pathStatusText = "Matching only"
            testEQDisabledReason = "Enable Pass-through first"
        }
    }

    private func isPassThroughFailure(_ error: String) -> Bool {
        let keys = [
            "pass-through", "process tap", "system audio", "pin a hardware",
            "bridge", "dac before", "macos 14.2"
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
                statusTitle = String(format: "EQ out%+.0f", peqOutputGainDB)
            } else if let format = deviceFormat {
                statusTitle = "PT \(format.shortDescription)"
            } else {
                statusTitle = "PT On"
            }
            return
        }
        if isPassThroughEnabled {
            statusTitle = lastError == nil ? "PT…" : "PT Err"
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
