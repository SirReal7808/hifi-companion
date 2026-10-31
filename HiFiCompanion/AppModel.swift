import AppKit
import Combine
import CoreAudio
import Foundation
import os.log

/// Menu-bar Appearance: follow system or force Light / Dark.
enum AppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor
    func applyToApp() {
        // AppModel.shared can initialize before NSApp exists; skip until start().
        guard let app = NSApp else { return }
        switch self {
        case .system:
            app.appearance = nil
        case .light:
            app.appearance = NSAppearance(named: .aqua)
        case .dark:
            app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var devices: [AudioOutputDevice] = []
    /// User-picked output (docs/redesign-0.3.md → Output). nil = follow macOS.
    @Published private(set) var preferredOutputUID: String?
    /// Device the equalizer and SB matching act on: the macOS output, unless it is virtual.
    @Published private(set) var outputDevice: AudioOutputDevice?
    /// App holding the output exclusively (hog mode); the equalizer is suspended meanwhile.
    @Published private(set) var exclusiveOutputOwner: String?
    /// Apple Music Mode switch (persisted; on by default): match the output's SB to the track,
    /// only while Music is the sole app playing there.
    @Published private(set) var isAppleMusicModeEnabled = true
    /// Observe-only view of what plays and how it reaches the output (docs/redesign-0.3.md).
    @Published private(set) var signalPath: SignalPath = .idle
    @Published private(set) var detectedFormat: AudioFormatInfo?
    @Published private(set) var deviceFormat: AudioFormatInfo?
    @Published private(set) var lastError: String?
    /// True while another audible app is using the Music-facing device (Apple Music mode lock).
    @Published private(set) var isMatchingLocked = false
    @Published private(set) var competingClientSummary: String?
    /// The user's Parametric Equalizer switch (persisted). The bridge may be briefly down
    /// while this stays on: output change, sleep / wake, exclusive player, SB rebuild.
    @Published private(set) var isPassThroughEnabled = false
    /// True only while the process-tap → DAC bridge is actually running.
    @Published private(set) var isBridgeRunning = false {
        didSet {
            if oldValue != isBridgeRunning { updateMeterTimer() }
        }
    }
    @Published private(set) var pathStatusText = "Matching only"
    /// Capture meter line while pass-through is running (tap RMS from other apps).
    @Published private(set) var signalMeterText = ""
    @Published private(set) var isHearingAudio = false
    /// Tap level (pre-EQ RMS, dBFS, 1 dB steps) for the Diagnostics meter; nil = silence / off.
    @Published private(set) var inputLevelDBFS: Double?
    /// Used PEQ bands only (0…10); live while Pass-through is on.
    /// True while the graph Sweep press-drag is held (tone audible / fading).
    @Published private(set) var peqSweepPlaying = false
    /// Short reason when PEQ panel controls are disabled.
    @Published private(set) var testEQDisabledReason = "Turn on Parametric Equalizer first"
    /// `--eq-unlock-controls`: allow EQ UI edits without a live bridge (Mac UI tests).
    @Published private(set) var eqControlsUnlockedForTesting = false

    func unlockEQControlsForTesting() {
        eqControlsUnlockedForTesting = true
        if testEQDisabledReason == "Turn on Parametric Equalizer first" {
            testEQDisabledReason = ""
        }
    }

    /// EQ panel controls stay usable while PT is on — including brief sample-rate rebuilds —
    /// so the panel does not flash a disabled banner and reflow.
    var eqControlsAvailable: Bool {
        if eqControlsUnlockedForTesting { return true }
        if isBridgeRunning { return true }
        // Mid-rebuild: bridge is intentionally down for a moment; keep the panel live.
        if isPassThroughEnabled && isPassThroughRebuilding { return true }
        return false
    }

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
    private static let safetyNetInterval: TimeInterval = 5
    /// Signal meter refresh; runs only while the equalizer bridge is running.
    private var meterTimer: Timer?
    /// One-shot re-check when an exclusive-Music lock / unlock grace period is pending.
    private var lockGraceTask: Task<Void, Never>?
    private var trackMonitor: MusicTrackMonitor?
    private lazy var outputMonitor = OutputMonitor(deviceManager: deviceManager)
    /// Throttles automatic re-attach attempts (device change, wake, failure).
    private var lastRebuildAttempt = Date.distantPast
    private var lastWakeAt = Date.distantPast
    private static let wakeSettleInterval: TimeInterval = 15
    /// Serializes enable/disable so a second menu click cannot race mid-flight.
    private var passThroughOp: Task<Void, Never>?
    private var passThroughBusy = false
    private var passThroughPendingTarget: Bool?
    /// Switch target not yet applied (cleared once its deferred apply has run).
    private var equalizerRequest: Bool?
    /// Serializes tap-graph rebuilds after SB / rate changes (avoids overlapping tear-downs).
    private var formatRebuildTask: Task<Void, Never>?
    private var formatRebuildGeneration: UInt64 = 0
    /// True while tap graph is intentionally stopped for an SB rebuild (poll must not clear PT).
    private var isPassThroughRebuilding = false
    private static let preferredOutputKey = "preferredOutputDeviceUID"
    private static let equalizerEnabledKey = "equalizerEnabled"
    private static let appleMusicModeKey = "appleMusicModeEnabled"
    /// Pre-0.3 keys: the pinned DAC becomes the preferred output; BlackHole-era keys are dropped.
    private static let legacyPinnedDeviceKey = "pinnedOutputDeviceUID"
    private static let legacyKeys = ["passThroughPreviousDefaultUID", "passThroughPreviousDefaultInputUID"]
    private static let appearancePreferenceKey = "appearancePreference"

    /// The EQ document (bands, output gain, profiles, undo, persistence).
    let peq = PEQDocument()
    private var peqChangeSubscription: AnyCancellable?
    /// Menu-bar Appearance override (System / Light / Dark). Follows system when `.system`.
    @Published private(set) var appearancePreference: AppearancePreference = .system
    /// Settings → General: items added to the menu bar title (none = placeholder only).
    @Published private(set) var menuBarTitleItems: Set<MenuBarTitleItem> = []
    /// Settings → Apps: bundle IDs left out of the equalizer (persisted; not read by the tap yet).
    @Published private(set) var excludedAppBundleIDs: [String] = []
    private static let menuBarTitleItemsKey = "menuBarTitleItems"
    private static let welcomeSeenKey = "welcomeSeen"
    private static let firstLaunchDoneKey = "firstLaunchDone"

    /// Shown in the menu under matching status.
    static let appleMusicModeMenuNote =
        "Apple Music Mode matches the output's sample rate and bit depth to the playing track, only while Music is the only app playing to it."

    static let passThroughMenuNote =
        "Parametric Equalizer processes other apps' audio on its way to the current output."

    /// EQ is “active” when PT is running, bands are not bypassed, and at least one band colors the signal.
    var isEQActive: Bool { isBridgeRunning && passThroughBridge.isEQColoring }

    var eqStatusText: String {
        guard isBridgeRunning else {
            return "EQ: off (matching-only is dry)"
        }
        if peq.bypass {
            if peq.bypassGainMatch {
                return "EQ: bypassed · out \(EQFormat.gainDB(peq.outputGainDB, fractionDigits: 1)) (bands skipped)"
            }
            return "EQ: bypassed · true dry (unity)"
        }
        if isEQActive {
            let peak = EQFormat.gainDB(peq.peakBoostDB, fractionDigits: 1, includeUnit: false)
            return "EQ: active · out \(EQFormat.gainDB(peq.outputGainDB, fractionDigits: 1)) · peak \(peak) (not bit-perfect)"
        }
        return "EQ: flat · out \(EQFormat.gainDB(peq.outputGainDB, fractionDigits: 1))"
    }

    private init() {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.preferredOutputKey) == nil,
           let legacyPin = defaults.string(forKey: Self.legacyPinnedDeviceKey) {
            defaults.set(legacyPin, forKey: Self.preferredOutputKey)
        }
        defaults.removeObject(forKey: Self.legacyPinnedDeviceKey)
        Self.legacyKeys.forEach(defaults.removeObject(forKey:))
        preferredOutputUID = defaults.string(forKey: Self.preferredOutputKey)
        isAppleMusicModeEnabled = defaults.object(forKey: Self.appleMusicModeKey) as? Bool ?? true
        let titleItems = defaults.stringArray(forKey: Self.menuBarTitleItemsKey) ?? []
        menuBarTitleItems = Set(titleItems.compactMap(MenuBarTitleItem.init(rawValue:)))
        excludedAppBundleIDs = EqualizerExclusions.normalized(
            defaults.stringArray(forKey: EqualizerExclusions.defaultsKey) ?? []
        )
        if let raw = UserDefaults.standard.string(forKey: Self.appearancePreferenceKey),
           let pref = AppearancePreference(rawValue: raw) {
            appearancePreference = pref
        }
        applyAppearancePreference()
        peq.sampleRateProvider = { [unowned self] in self.peqSampleRateForHeadroom() }
        peq.onChange = { [unowned self] change in self.applyPEQChange(change) }
        // Views observe AppModel; republish document changes.
        peqChangeSubscription = peq.objectWillChange.sink { [unowned self] _ in
            self.objectWillChange.send()
        }
        applyPEQChange([.toneLevel, .dsp])
    }

    /// System / Light / Dark — persists and updates `NSApp.appearance`.
    func setAppleMusicModeEnabled(_ enabled: Bool) {
        guard enabled != isAppleMusicModeEnabled else { return }
        isAppleMusicModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.appleMusicModeKey)
        refreshExclusiveLock()
        if enabled {
            // Catch up with the track that is playing now.
            Task { await applyAcceptedDetectionIfNeeded(force: true) }
        }
        refreshSignalPath()
    }

    func setAppearancePreference(_ preference: AppearancePreference) {
        guard preference != appearancePreference else { return }
        appearancePreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.appearancePreferenceKey)
        applyAppearancePreference()
    }

    /// Menu bar title: the placeholder, or the selected Device / SB / Profile items.
    var menuBarTitle: String {
        MenuBarTitle.compose(
            items: menuBarTitleItems,
            device: outputDevice?.name,
            sampleFormat: deviceFormat.map(MenuBarTitle.compactFormat),
            profile: peq.activeProfileName.map { peq.profileDirty ? "\($0)*" : $0 }
        )
    }

    func setMenuBarTitleItem(_ item: MenuBarTitleItem, shown: Bool) {
        var next = menuBarTitleItems
        if shown { next.insert(item) } else { next.remove(item) }
        guard next != menuBarTitleItems else { return }
        menuBarTitleItems = next
        UserDefaults.standard.set(
            MenuBarTitleItem.allCases.filter(next.contains).map(\.rawValue),
            forKey: Self.menuBarTitleItemsKey
        )
    }

    func addExcludedApps(_ bundleIDs: [String]) {
        setExcludedApps(excludedAppBundleIDs + bundleIDs)
    }

    func removeExcludedApp(_ bundleID: String) {
        setExcludedApps(excludedAppBundleIDs.filter { $0 != bundleID })
    }

    private func setExcludedApps(_ bundleIDs: [String]) {
        let next = EqualizerExclusions.normalized(bundleIDs)
        guard next != excludedAppBundleIDs else { return }
        excludedAppBundleIDs = next
        UserDefaults.standard.set(next, forKey: EqualizerExclusions.defaultsKey)
    }

    // MARK: - Parametric Equalizer switch / first run

    /// The first-run explainer has been shown (or the user already used the equalizer).
    var hasSeenWelcome: Bool { UserDefaults.standard.bool(forKey: Self.welcomeSeenKey) }

    /// Panel switch. The first time it turns on, the explainer comes first: the System Audio
    /// Recording prompt appears when the tap is created (docs/redesign-0.3.md → First run).
    func setEqualizerEnabled(_ enabled: Bool) {
        // Compare with the pending request: `isPassThroughEnabled` flips only after the
        // deferred apply, so a quick on → off must not be dropped.
        guard enabled != (equalizerRequest ?? isPassThroughEnabled) else { return }
        if enabled && !hasSeenWelcome {
            AuxWindows.shared.showWelcome()
            return
        }
        requestEqualizer(enabled)
    }

    /// Welcome window buttons.
    /// "Not Now" only closes it, so it comes back before the first real enable.
    func finishWelcome(turnOnEqualizer: Bool) {
        AuxWindows.shared.closeWelcome()
        guard turnOnEqualizer else { return }
        UserDefaults.standard.set(true, forKey: Self.welcomeSeenKey)
        if !(equalizerRequest ?? isPassThroughEnabled) {
            requestEqualizer(true)
        }
    }

    /// Launch: a fresh install shows the explainer; an existing user (who already saw the
    /// permission prompt) is marked as having seen it.
    private func shouldShowWelcomeOnLaunch() -> Bool {
        let defaults = UserDefaults.standard
        let decision = FirstRun.launchDecision(
            welcomeSeen: hasSeenWelcome,
            usedBefore: defaults.object(forKey: Self.equalizerEnabledKey) != nil
                || defaults.object(forKey: PEQDocument.deviceCurvesDefaultsKey) != nil,
            firstLaunchDone: defaults.bool(forKey: Self.firstLaunchDoneKey)
        )
        switch decision {
        case .none:
            return false
        case .markSeen:
            defaults.set(true, forKey: Self.welcomeSeenKey)
            return false
        case .show:
            defaults.set(true, forKey: Self.firstLaunchDoneKey)
            return true
        }
    }

    private func applyAppearancePreference() {
        appearancePreference.applyToApp()
    }

    /// Opens the floating EQ panel.
    func showPEQPanel() {
        PEQPanelController.shared.show()
    }

    // MARK: - Sweep

    func beginPEQSweep(atHz hz: Double) {
        guard isBridgeRunning else { return }
        let clamped = min(EQBand.maxFrequencyHz, max(EQBand.minFrequencyHz, hz))
        peq.setSweepNeedle(hz: clamped)
        peqSweepPlaying = true
        passThroughBridge.setSweepToneLevelDB(peq.toneLevelDB)
        passThroughBridge.beginSweepTone(frequencyHz: clamped)
    }

    func updatePEQSweep(atHz hz: Double) {
        guard isBridgeRunning, peqSweepPlaying else { return }
        let clamped = min(EQBand.maxFrequencyHz, max(EQBand.minFrequencyHz, hz))
        peq.setSweepNeedle(hz: clamped)
        passThroughBridge.updateSweepTone(frequencyHz: clamped)
    }

    /// Mute tone and park the needle at the last frequency.
    func endPEQSweep() {
        peqSweepPlaying = false
        passThroughBridge.endSweepTone()
        peq.persist()
    }

    func mutePEQSweep() {
        peqSweepPlaying = false
        passThroughBridge.hardMuteSweepTone()
    }

    private func peqSampleRateForHeadroom() -> Double {
        let live = passThroughBridge.graphSampleRate
        if live > 0 { return live }
        return deviceFormat?.sampleRate ?? 48_000
    }

    /// Side effects of a document edit (see `PEQDocument.Change`).
    private func applyPEQChange(_ change: PEQDocument.Change) {
        if change.contains(.toneLevel) {
            passThroughBridge.setSweepToneLevelDB(peq.toneLevelDB)
        }
        if change.contains(.dsp) {
            pushPEQToBridge()
        }
        if change.contains(.status) {
            updatePathStatus()
            refreshSignalPath()
        }
    }

    private func pushPEQToBridge() {
        passThroughBridge.applyPEQ(
            bands: peq.bands,
            outputGainDB: peq.outputGainDB,
            bypass: peq.bypass,
            applyOutputGainWhenBypassed: peq.bypassGainMatch
        )
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
        // Decide before the first output switch persists a device curve.
        let showWelcome = shouldShowWelcomeOnLaunch()
        applyAppearancePreference()
        refreshDevices()
        outputMonitor.onEvent = { [weak self] event in self?.handleOutputEvent(event) }
        outputMonitor.start()
        selectPreferredOutputIfNeeded(at: .launch)
        refreshOutputDevice()
        refreshPinnedDeviceFormat()
        refreshExclusiveLock()
        updatePathStatus()
        refreshSignalPath()

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

        outputMonitor.watchOutputDevice(outputDevice?.id)
        // Events drive everything (OutputMonitor); this slow pass only catches a missed one
        // and retries a failed re-attach. It used to run every 0.4 s.
        devicePollTimer = Timer.scheduledTimer(withTimeInterval: Self.safetyNetInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDevices()
                self?.refreshPinnedDeviceFormat()
                self?.refreshExclusiveLock()
                self?.syncBridgeRunningFlag()
                self?.reconcilePassThroughFormatIfNeeded()
            }
        }

        if showWelcome { AuxWindows.shared.showWelcome() }
        if UserDefaults.standard.bool(forKey: Self.equalizerEnabledKey) {
            passThroughOp = Task { @MainActor [weak self] in
                await self?.applyPassThrough(enabled: true)
            }
        }
    }

    /// Headless check: play into DAC first → enable process-tap PT (default stays DAC) → tap RMS → disable.
    /// Does **not** treat Test tone as Signal success.
    func runPassThroughSmokeTest() async -> Int32 {
        refreshDevices()
        let beforeUID = deviceManager.defaultOutputDevice()?.uid
        let dac = outputDevice
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
        if !pathStatusText.hasPrefix("Parametric Equalizer →") {
            print("SMOKE: FAIL path status not Parametric Equalizer → (got \(pathStatusText))")
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
            disablePassThrough()
            return 1
        }
        print("SMOKE: OK")
        return 0
    }

    // MARK: - Diagnostics (Settings)

    /// Output device facts, read on demand while Diagnostics is open.
    func outputDeviceDetails() -> OutputDeviceDetails? {
        outputDevice.map { deviceManager.details(for: $0.id) }
    }

    /// Where the Apple Music track format came from (log line kind or AppleScript).
    var detectionSourceLabel: String? {
        acceptedDetection?.source.label
    }

    /// Sample rate the equalizer processes at (the tap's rate), when running.
    var equalizerSampleRate: Double? {
        guard isBridgeRunning else { return nil }
        let rate = passThroughBridge.graphSampleRate
        return rate > 0 ? rate : nil
    }

    /// Automation entry points used by `--hold-passthrough-seconds` / smoke helpers.
    func applyPassThroughForAutomation(enabled: Bool) async {
        await applyPassThrough(enabled: enabled)
    }

    func bridgeMeterForAutomation() -> PassThroughMeter {
        refreshSignalMeter()
        return passThroughBridge.currentMeter()
    }

    func passThroughBridgeForAutomation() -> PassThroughBridge {
        passThroughBridge
    }

    func graphSampleRateForAutomation() -> Double {
        passThroughBridge.graphSampleRate
    }

    func setEQGainForAutomation(_ gainDB: Double) {
        // Map legacy single-band smoke onto a 1 kHz peaking band (create if needed).
        if peq.bands.first(where: { abs($0.frequencyHz - 1_000) < 1 }) == nil {
            guard let id = peq.addBand() else { return }
            peq.updateBand(id: id) { $0.frequencyHz = 1_000 }
        }
        if let band = peq.bands.first(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            peq.updateBand(id: band.id) { $0.gainDB = gainDB; $0.enabled = true; $0.filterType = .peaking }
        }
        peq.setBypass(false)
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
        let at1k = PEQHeadroom.peakBoostDB(bands: peq.bands, sampleRate: peqSampleRateForHeadroom())
        let ok = boost > gainDB - 3.0 && at1k > gainDB - 3.0
        print("EQ_PROOF: bandGain=\(gainDB) peakBoost=\(boost) status=\(eqStatusText) ok=\(ok)")
        setEQGainForAutomation(0)
        return ok
    }

    func stop() {
        passThroughPendingTarget = nil
        outputMonitor.stop()
        // Quitting keeps the user's (persisted) switch for the next launch.
        disablePassThrough()
        detectorTask?.cancel()
        detectorTask = nil
        trackMonitor?.stop()
        trackMonitor = nil
        detector.stop()
        devicePollTimer?.invalidate()
        devicePollTimer = nil
        meterTimer?.invalidate()
        meterTimer = nil
        lockGraceTask?.cancel()
        lockGraceTask = nil
        reattachRetryTask?.cancel()
        reattachRetryTask = nil
    }

    func refreshDevices() {
        let next = deviceManager.pinnableOutputDevices()
        // Equality-guard: unconditional assign republishes EnvironmentObject and
        // redraws the frosted EQ panel ~2.5×/s while idle (CPU / WindowServer).
        if next != devices {
            devices = next
        }
        refreshOutputDevice()
        updatePathStatus()
    }

    /// The macOS output, unless it is virtual. Equality-guarded (polled).
    private func refreshOutputDevice() {
        let next = OutputPolicy.target(systemOutput: deviceManager.defaultOutputDevice())
        guard next != outputDevice else { return }
        outputDevice = next
        outputDidChange()
    }

    /// Move the equalizer and SB matching to the new output.
    private func outputDidChange() {
        log.info("Output → \(self.outputDevice?.name ?? "none", privacy: .public)")
        outputMonitor.watchOutputDevice(outputDevice?.id)
        // Each output keeps its own curve; load it before the tap moves to the device.
        if let device = outputDevice {
            peq.switchDevice(uid: device.uid, name: device.name)
        }
        lastRebuildAttempt = .distantPast
        refreshPinnedDeviceFormat()
        refreshExclusiveLock()
        // Re-matching SB rebuilds the tap itself; a second rebuild would add a dropout.
        let sbMatchWillRebuild = acceptedDetection != nil && !isMatchingLocked
        if isPassThroughEnabled && !sbMatchWillRebuild {
            schedulePassThroughRebuild(reason: "output-changed")
        }
        Task { await applyAcceptedDetectionIfNeeded(force: true) }
        updatePathStatus()
        refreshSignalPath()
    }

    /// Menu / Settings: nil = follow macOS (clears the preference).
    func selectOutput(_ device: AudioOutputDevice?) {
        preferredOutputUID = device?.uid
        UserDefaults.standard.set(preferredOutputUID, forKey: Self.preferredOutputKey)
        selectPreferredOutputIfNeeded(at: .userSelected)
    }

    func isPreferredOutput(_ device: AudioOutputDevice) -> Bool {
        device.uid == preferredOutputUID
    }

    /// Make the preferred device the macOS output at the moments `OutputPolicy` allows.
    private func selectPreferredOutputIfNeeded(at moment: OutputPolicy.Moment) {
        let available = Set(deviceManager.pinnableOutputDevices().map(\.uid))
        guard let uid = OutputPolicy.systemOutputToSelect(
            at: moment,
            preferredUID: preferredOutputUID,
            availableUIDs: available,
            systemOutputUID: deviceManager.defaultOutputDevice()?.uid
        ) else { return }
        do {
            try deviceManager.setDefaultOutputDevice(uid: uid)
            log.info("macOS output → preferred \(uid, privacy: .public)")
        } catch {
            lastError = "Could not switch the macOS output: \(error.localizedDescription)"
        }
    }

    private func handleOutputEvent(_ event: OutputMonitor.Event) {
        switch event {
        case .devicesChanged(let added, _):
            refreshDevices()
            // A USB DAC can re-enumerate on wake; that is not a plug-in, so it must not
            // override a manual macOS output choice.
            if !added.isEmpty, Date().timeIntervalSince(lastWakeAt) > Self.wakeSettleInterval {
                selectPreferredOutputIfNeeded(at: .devicesAdded(added))
            }
        case .systemOutputChanged:
            break
        case .outputDeviceStateChanged:
            refreshPinnedDeviceFormat()
            reconcilePassThroughFormatIfNeeded()
        case .processActivityChanged:
            refreshExclusiveLock()
            return
        case .didWake:
            // Taps and aggregates do not survive sleep reliably — re-attach.
            lastWakeAt = Date()
            lastRebuildAttempt = .distantPast
            if isPassThroughEnabled {
                schedulePassThroughRebuild(reason: "wake")
            }
        }
        refreshOutputDevice()
        updatePathStatus()
        refreshSignalPath()
    }

    /// Menu action — coalesced/serialized.
    func togglePassThrough() {
        // The switch is the user's intent; the bridge may be briefly down while it is on.
        requestEqualizer(!(equalizerRequest ?? isPassThroughEnabled))
    }

    private func requestEqualizer(_ target: Bool) {
        // Only an explicit toggle is remembered; launch-time or transient failures keep it.
        UserDefaults.standard.set(target, forKey: Self.equalizerEnabledKey)
        equalizerRequest = target
        passThroughOp = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await self?.applyPassThrough(enabled: target)
            if self?.equalizerRequest == target { self?.equalizerRequest = nil }
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
            disablePassThrough()
        }
    }

    private func enablePassThrough() async {
        lastError = nil
        // The switch is on from this request; transient problems leave it on and
        // `reconcilePassThroughFormatIfNeeded` retries. Only a permission denial turns it off.
        isPassThroughEnabled = true
        lastRebuildAttempt = Date()
        guard let dac = outputDevice, exclusiveOutputOwner == nil else {
            publishBridgeUI(running: false, clearingEnabled: false)
            return
        }

        formatRebuildGeneration &+= 1
        let generation = formatRebuildGeneration
        do {
            if let format = acceptedDetection?.format ?? detectedFormat ?? deviceFormat {
                _ = try? deviceManager.apply(format: format, to: dac.id)
            }

            pushPEQToBridge()

            try await Task.detached(priority: .userInitiated) { [passThroughBridge, dac] in
                try passThroughBridge.start(outputDeviceID: dac.id, outputDeviceUID: dac.uid)
            }.value
            // A wake / output-change rebuild took over meanwhile; it owns the bridge now.
            guard generation == formatRebuildGeneration else { return }

            guard passThroughBridge.isRunning else {
                throw PassThroughError.engine("Bridge reported not running after start.")
            }

            // Re-apply after start so sections match the live tap sample rate.
            pushPEQToBridge()

            let meter = passThroughBridge.currentMeter()
            guard meter.outputDeviceID == dac.id else {
                throw PassThroughError.engine(
                    "Playback device is \(meter.outputDeviceID), not the output \(dac.id) (\(dac.name))."
                )
            }

            lastError = nil
            publishBridgeUI(running: true)
            refreshSignalMeter()
            log.info("Process-tap Pass-through enabled → \(dac.name, privacy: .public)")
            refreshExclusiveLock()
        } catch {
            guard generation == formatRebuildGeneration else { return }
            passThroughBridge.stop()
            lastError = Self.formatPassThroughFailure(error)
            if case PassThroughError.tapPermissionDenied = error {
                UserDefaults.standard.set(false, forKey: Self.equalizerEnabledKey)
                publishBridgeUI(running: false)
            } else {
                publishBridgeUI(running: false, clearingEnabled: false)
            }
            log.error("Equalizer start failed: \(self.lastError ?? "", privacy: .public)")
        }
    }

    private static func formatPassThroughFailure(_ error: Error) -> String {
        error.localizedDescription
    }

    private func publishBridgeUI(running: Bool, clearingEnabled: Bool = true) {
        isBridgeRunning = running
        if running {
            isPassThroughEnabled = true
            lastError = nil
        } else {
            peqSweepPlaying = false
            if clearingEnabled {
                isPassThroughEnabled = false
                signalMeterText = ""
                isHearingAudio = false
            } else {
                // Mid-rebuild: keep Pass-through “on” while the tap graph is torn down briefly.
                signalMeterText = "Signal: reconnecting…"
                isHearingAudio = false
            }
        }
        updatePathStatus()
        refreshSignalPath()
    }

    private func updateMeterTimer() {
        if isBridgeRunning, meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshSignalMeter() }
            }
            refreshSignalMeter()
        } else if !isBridgeRunning, let timer = meterTimer {
            timer.invalidate()
            meterTimer = nil
        }
    }

    private func refreshSignalMeter() {
        guard isBridgeRunning else {
            if !signalMeterText.isEmpty {
                signalMeterText = ""
                isHearingAudio = false
            }
            if inputLevelDBFS != nil { inputLevelDBFS = nil }
            return
        }
        let meter = passThroughBridge.currentMeter()
        let level = SignalLevel.dbfs(rms: meter.capturePeakRMS).map { $0.rounded() }
        if inputLevelDBFS != level {
            inputLevelDBFS = level
        }
        let line = meter.menuLine
        if signalMeterText != line {
            signalMeterText = line
        }
        if isHearingAudio != meter.isHearingAudio {
            isHearingAudio = meter.isHearingAudio
        }
    }

    private func disablePassThrough() {
        // Invalidate any in-flight rebuild so it cannot turn the bridge back on.
        formatRebuildGeneration &+= 1
        formatRebuildTask?.cancel()
        isPassThroughRebuilding = false
        passThroughBridge.stop()
        lastError = nil
        publishBridgeUI(running: false)
        refreshExclusiveLock()
        log.info("Parametric Equalizer off")
    }

    /// Tear down tap+aggregate and rebuild at the DAC’s current rate (keeps EQ gain).
    private func rebuildPassThroughGraph(reason: String) async {
        guard isPassThroughEnabled else {
            isPassThroughRebuilding = false
            return
        }
        lastRebuildAttempt = Date()
        // No hardware output, or another app holds it exclusively: stay down but keep the
        // switch on; `reconcilePassThroughFormatIfNeeded` re-attaches when that clears.
        guard let output = outputDevice, exclusiveOutputOwner == nil else {
            isPassThroughRebuilding = false
            passThroughBridge.stop()
            publishBridgeUI(running: false, clearingEnabled: false)
            return
        }

        formatRebuildGeneration &+= 1
        let generation = formatRebuildGeneration
        isPassThroughRebuilding = true
        defer {
            if generation == formatRebuildGeneration {
                isPassThroughRebuilding = false
                // Events (rate change, exclusive grab) that arrived while rebuilding were
                // skipped by reconcile; replay once now instead of waiting for the safety net.
                DispatchQueue.main.async { [weak self] in self?.reconcilePassThroughFormatIfNeeded() }
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
            guard isPassThroughEnabled else {
                // Switched off while starting.
                passThroughBridge.stop()
                return
            }
            if passThroughBridge.isRunning {
                pushPEQToBridge()
                lastError = nil
                publishBridgeUI(running: true)
                let graphHz = passThroughBridge.graphSampleRate
                let dacHz = deviceManager.currentFormat(for: output.id)?.sampleRate ?? 0
                print("REBUILD_OK reason=\(reason) graph=\(graphHz) dac=\(dacHz) outGain=\(peq.outputGainDB)")
                log.info("Pass-through rebuilt (\(reason, privacy: .public)) graph=\(graphHz, privacy: .public)Hz dac=\(dacHz, privacy: .public)Hz out=\(self.peq.outputGainDB, privacy: .public)dB")
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
            if case PassThroughError.tapPermissionDenied = error {
                // Permission revoked: stop retrying; the user turns the switch back on.
                UserDefaults.standard.set(false, forKey: Self.equalizerEnabledKey)
                publishBridgeUI(running: false)
            } else {
                publishBridgeUI(running: false, clearingEnabled: false)
            }
            print("REBUILD_FAIL reason=\(reason) error=\(lastError ?? "")")
            log.error("Bridge rebuild failed: \(self.lastError ?? "", privacy: .public)")
        }
    }

    /// If the DAC rate moved under a live tap graph, rebuild (handles SB changes that
    /// finished after the first restart, or external rate changes).
    /// While the switch is on, keep the bridge attached to the current output: re-attach after
    /// an output change, wake, exclusive release or failure; rebuild on a DAC rate change.
    private func reconcilePassThroughFormatIfNeeded() {
        refreshExclusiveOwner()
        guard isPassThroughEnabled, !isPassThroughRebuilding, let output = outputDevice else { return }
        let running = passThroughBridge.isRunning
        if exclusiveOutputOwner != nil {
            if running {
                passThroughBridge.stop()
                publishBridgeUI(running: false, clearingEnabled: false)
            }
            return
        }
        if !running || passThroughBridge.attachedOutputDeviceID != output.id {
            // Throttled so a persistent failure (e.g. permission revoked) does not spin.
            let sinceLast = Date().timeIntervalSince(lastRebuildAttempt)
            guard sinceLast > Self.reattachInterval else {
                scheduleReattachRetry(after: Self.reattachInterval - sinceLast)
                return
            }
            lastRebuildAttempt = Date()
            schedulePassThroughRebuild(reason: running ? "output-mismatch" : "reattach")
            return
        }
        guard let dacFormat = deviceManager.currentFormat(for: output.id),
              passThroughBridge.graphMismatchesDAC(sampleRate: dacFormat.sampleRate)
        else { return }
        log.info("DAC rate \(dacFormat.sampleRate, privacy: .public) ≠ graph \(self.passThroughBridge.graphSampleRate, privacy: .public) — scheduling rebuild")
        schedulePassThroughRebuild(reason: "dac-rate-drift")
    }

    private static let reattachInterval: TimeInterval = 5
    private var reattachRetryTask: Task<Void, Never>?

    /// One-shot retry when the throttle window ends (the safety net alone could add 5 s).
    private func scheduleReattachRetry(after delay: TimeInterval) {
        guard reattachRetryTask == nil else { return }
        reattachRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.05) * 1_000_000_000) + 50_000_000)
            self?.reattachRetryTask = nil
            guard !Task.isCancelled else { return }
            self?.reconcilePassThroughFormatIfNeeded()
        }
    }

    /// Name of the app holding the output in hog mode (exclusive), if any.
    private func refreshExclusiveOwner() {
        var owner: String?
        if let output = outputDevice,
           let pid = deviceManager.hogModeOwner(output.id),
           pid != getpid() {
            owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Another app"
        }
        guard owner != exclusiveOutputOwner else { return }
        exclusiveOutputOwner = owner
        if owner == nil {
            lastRebuildAttempt = .distantPast
        }
        updatePathStatus()
        refreshSignalPath()
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

    private func syncBridgeRunningFlag() {
        let running = passThroughBridge.isRunning
        if isPassThroughRebuilding {
            // Intentional tear-down for sample-rate rebuild — do not clear enabled or raise error.
            if isBridgeRunning != running {
                isBridgeRunning = running
                updatePathStatus()
                refreshSignalPath()
            }
            return
        }
        if isBridgeRunning != running || isPassThroughEnabled != running {
            if running {
                // Bridge is live — UI must match (clears stale red errors from a raced toggle).
                publishBridgeUI(running: true)
            } else if isPassThroughEnabled {
                // Output gone, exclusive player, sleep: keep the switch on; reconcile re-attaches.
                if isBridgeRunning {
                    isBridgeRunning = false
                    updatePathStatus()
                    refreshSignalPath()
                }
            } else {
                isBridgeRunning = false
                updatePathStatus()
                refreshSignalPath()
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
        refreshSignalPath()
    }

    /// Device where Music (and other apps) render when matching lock is evaluated.
    /// Process-tap Pass-through keeps apps on the real DAC (muted while tapped).
    private func musicFacingDevice() -> AudioOutputDevice? {
        outputDevice
    }

    private func refreshExclusiveLock() {
        defer { refreshSignalPath() }
        // Mode off: no matching, so nothing to lock.
        guard isAppleMusicModeEnabled, let device = musicFacingDevice() else {
            competingClientSummary = nil
            if isMatchingLocked {
                isMatchingLocked = false
                exclusiveLock.reset()
                refreshSignalPath()
            }
            return
        }

        let competitors = clientProbe.competingOutputClients(on: device.id)
        let nextSummary: String? = competitors.isEmpty
            ? nil
            : competitors.prefix(2).map(\.bundleID).joined(separator: ", ")
        if competingClientSummary != nextSummary {
            competingClientSummary = nextSummary
        }

        let event = exclusiveLock.update(competingAudible: !competitors.isEmpty)
        let wasLocked = isMatchingLocked
        let nextLocked = exclusiveLock.isLocked
        if isMatchingLocked != nextLocked {
            isMatchingLocked = nextLocked
        }
        // Without a fast poll, re-check once the pending lock / unlock grace has elapsed.
        lockGraceTask?.cancel()
        if competitors.isEmpty == nextLocked {
            let wait = max(exclusiveLock.lockGrace, exclusiveLock.unlockGrace) + 0.05
            lockGraceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.refreshExclusiveLock()
            }
        }

        switch event {
        case .locked:
            refreshSignalPath()
        case .unlocked:
            Task { await applyAcceptedDetectionIfNeeded(force: true) }
            refreshSignalPath()
        case .unchanged:
            if wasLocked != nextLocked {
                refreshSignalPath()
            }
        }
    }

    private func applyAcceptedDetectionIfNeeded(force: Bool) async {
        guard isAppleMusicModeEnabled, !isMatchingLocked else { return }
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
            refreshSignalPath()
        } catch {
            isPassThroughRebuilding = false
            lastError = error.localizedDescription
            if isPassThroughEnabled, !passThroughBridge.isRunning {
                schedulePassThroughRebuild(reason: "sb-match-recovery")
            }
        }
    }

    private func resolveHardwareDAC() -> AudioOutputDevice? {
        outputDevice
    }

    /// Display name for a playing process: the owning app for helpers (Chrome, Edge, Safari),
    /// else the process's app name, else its bundle ID. Apple Music stays "Apple Music"
    /// regardless of the system language (product UI is English).
    private static func appName(for client: AudibleClient) -> String {
        let owner = SignalPath.owningAppBundleID(of: client.bundleID)
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: owner).first,
           let name = app.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return NSRunningApplication(processIdentifier: client.pid)?.localizedName ?? client.bundleID
    }

    /// Recompute the signal path from current device state. Equality-guarded.
    private func refreshSignalPath() {
        let next: SignalPath
        if let output = outputDevice {
            let sources = clientProbe.outputClients(on: output.id).map { client -> SignalPath.Source in
                let isMusic = DeviceAudioClientProbe.musicBundleIDs.contains(client.bundleID)
                return SignalPath.Source(
                    appName: isMusic ? "Apple Music" : Self.appName(for: client),
                    format: isMusic ? detectedFormat : nil
                )
            }
            next = SignalPath.make(
                sources: sources,
                equalizer: isBridgeRunning ? .processing : .off,
                exclusiveApp: exclusiveOutputOwner,
                deviceName: output.name,
                deviceFormat: deviceFormat,
                isBluetooth: deviceManager.isBluetooth(output.id)
            )
        } else {
            next = .idle
        }
        if next != signalPath {
            signalPath = next
        }
    }

    private func refreshPinnedDeviceFormat() {
        guard let device = outputDevice else {
            if deviceFormat != nil {
                deviceFormat = nil
                refreshSignalPath()
            }
            return
        }
        let format = deviceManager.currentFormat(for: device.id)
        if deviceFormat != format {
            deviceFormat = format
        }
        refreshSignalPath()
    }

    private func updatePathStatus() {
        let nextPath: String
        let nextReason: String
        if isPassThroughEnabled && isBridgeRunning {
            let dacName = outputDevice?.name ?? "output"
            let eqTag: String = {
                let out = EQFormat.gainDB(peq.outputGainDB, fractionDigits: 0)
                if peq.bypass { return " · EQ bypass · out \(out)" }
                if isEQActive { return " · EQ · out \(out)" }
                return " · EQ flat · out \(out)"
            }()
            nextPath = "Parametric Equalizer → \(dacName)\(eqTag)"
            nextReason = ""
        } else if isPassThroughEnabled && !isBridgeRunning {
            // Menu-only status — never push this copy into `testEQDisabledReason`
            // (that caption reflowed the EQ panel when Music stopped / rate changed).
            if let owner = exclusiveOutputOwner {
                nextPath = "Parametric Equalizer unavailable — \(owner) exclusive"
                nextReason = "Unavailable — \(owner) exclusive"
            } else if outputDevice == nil {
                nextPath = "Parametric Equalizer waiting for a hardware output"
                nextReason = "No hardware output"
            } else if let error = lastError {
                nextPath = "Equalizer error: \(error)"
                nextReason = "Equalizer not running"
            } else {
                nextPath = "Parametric Equalizer reconnecting…"
                nextReason = ""
            }
        } else if let error = lastError, isPassThroughFailure(error) {
            nextPath = "Equalizer error: \(error)"
            nextReason = "Turn on Parametric Equalizer first"
        } else {
            nextPath = "Parametric Equalizer off"
            nextReason = "Turn on Parametric Equalizer first"
        }
        if pathStatusText != nextPath {
            pathStatusText = nextPath
        }
        if testEQDisabledReason != nextReason {
            testEQDisabledReason = nextReason
        }
    }

    private func isPassThroughFailure(_ error: String) -> Bool {
        let keys = [
            "pass-through", "process tap", "system audio", "pin a hardware",
            "bridge", "dac before", "macos 14.2", "equalizer", "hardware output"
        ]
        let lowered = error.lowercased()
        return keys.contains { lowered.contains($0) }
    }
}
