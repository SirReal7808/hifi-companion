import AVFoundation
import CoreAudio
import Darwin
import Foundation
import os.log

enum PassThroughError: LocalizedError {
    case missingDAC
    case unsupportedOS
    case tapPermissionDenied
    case tap(OSStatus, String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .missingDAC:
            return "No hardware output for the Parametric Equalizer."
        case .unsupportedOS:
            return "Process-tap Pass-through requires macOS 14.2 or later."
        case .tapPermissionDenied:
            return "System Audio Recording access denied. System Settings → Privacy & Security → Screen & System Audio Recording (or System Audio) → enable HiFi Companion, then turn the Parametric Equalizer on again."
        case .tap(let status, let context):
            return "Process tap error \(PassThroughError.describe(status)) while \(context)"
        case .engine(let message):
            return message
        }
    }

    static func describe(_ status: OSStatus) -> String {
        if status == noErr { return "noErr" }
        let u = UInt32(bitPattern: status)
        var four = ""
        for i in 0..<4 {
            let byte = UInt8(truncatingIfNeeded: (u >> (8 * (3 - i))) & 0xFF)
            four.append(Character(UnicodeScalar(byte)))
        }
        let printable = four.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet(charactersIn: "!@#$%^&*()_-+=.?'").contains($0)
        }
        return printable ? "\(status) ('\(four)')" : "\(status)"
    }
}

struct PassThroughMeter: Equatable {
    var capturePeakRMS: Float = 0
    var captureCallbacks: UInt64 = 0
    var renderCallbacks: UInt64 = 0
    var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    var sampleRate: Double = 0

    var isHearingAudio: Bool { capturePeakRMS >= 0.004 }

    var menuLine: String {
        if captureCallbacks == 0 {
            return "Signal: waiting for process tap…"
        }
        if isHearingAudio {
            let db = 20 * log10(max(capturePeakRMS, 1e-6))
            return String(format: "Signal: hearing audio (%.0f dBFS)", db)
        }
        return "Signal: silence (play Music / YouTube — already playing is OK)"
    }
}

/// Core Audio **process tap** → pinned DAC.
///
/// Does not change the system default device. Other apps keep targeting the DAC;
/// `muteBehavior = .mutedWhenTapped` silences their direct output while we read the
/// tap and play through our IOProc (same audible path as Test tone).
final class PassThroughBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "PassThroughBridge")
    private let queue = DispatchQueue(label: "com.hificompanion.passthrough")
    private let peq = PEQProcessor()
    private let sweep = SweepOscillator()
    private let meterLock = NSLock()
    private let toneLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    /// On-demand AVAudioEngine → pinned DAC for Sweep when the aggregate is idle.
    /// Our PID is excluded from the process tap, so this stays audible under
    /// `mutedWhenTapped`. Must **not** stay running while idle: a live engine on the
    /// same DAC fights the aggregate/Music path and can silence pass-through.
    private var dacWakeEngine: AVAudioEngine?
    private var dacWakeSource: AVAudioSourceNode?
    /// When the cold-DAC engine became audible; a release keeps the tone this long after it.
    private var dacWakeStartedAt = Date.distantPast
    /// Bumped on every press (on `queue`); a delayed release only ends its own gesture.
    private var sweepGesture: UInt64 = 0
    private static let minimumAudibleSweep: TimeInterval = 0.15
    private var engineSweepScratch: [Float] = []
    /// Reused mono scratch for Sweep mixed into the aggregate IOProc.
    private var sweepScratch: [Float] = []
    /// Raw aggregate IOProc entries (before render guards) for diagnostics.
    private var rawIOCallbackCount: UInt64 = 0
    /// Mach-ish timestamp of the last aggregate render (for “is Music waking IO?”).
    private var lastAggregateRenderHostTime: UInt64 = 0
    private var runningFlag = false
    private var meter = PassThroughMeter()
    private var peakDecayDeadline = Date.distantPast
    private var asbd = AudioStreamBasicDescription()
    private var channelCount: Int = 2
    /// Sample rate the tap/aggregate was opened at (for SB-change rebuild detection).
    private var openedSampleRate: Double = 0

    /// Pending one-shot test-tone samples (menu beep), mixed into output before PEQ.
    private var toneRemaining: [[Float]] = []
    private var toneFrameIndex = 0
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// State snapshot readable from any thread without waiting on `queue` (which `start`
    /// can hold for hundreds of ms). Written on `queue` at the end of start / stop.
    private let stateLock = NSLock()
    private var publishedRunning = false
    private var publishedSampleRate: Double = 0
    private var publishedOutputDeviceID = AudioDeviceID(kAudioObjectUnknown)

    var isRunning: Bool { stateLock.withLock { publishedRunning } }
    var isEQBypassed: Bool { peq.isBypassed }
    var isEQColoring: Bool { peq.isColoring }
    var peqOutputGainDB: Double { peq.currentOutputGainDB }
    /// Device the running bridge plays to; unknown when stopped.
    var attachedOutputDeviceID: AudioDeviceID { stateLock.withLock { publishedOutputDeviceID } }
    /// Rate the live tap graph was built for; 0 if not running.
    var graphSampleRate: Double { stateLock.withLock { publishedSampleRate } }

    /// Push the full 10-band PEQ + output gain onto the live process-tap path.
    func applyPEQ(
        bands: [EQBand],
        outputGainDB: Double,
        bypass: Bool,
        applyOutputGainWhenBypassed: Bool = true
    ) {
        peq.setState(
            bands: bands,
            outputGainDB: outputGainDB,
            bypass: bypass,
            applyOutputGainWhenBypassed: applyOutputGainWhenBypassed
        )
    }

    func peqPeakBoostDB() -> Double { peq.peakBoostDB() }

    /// Continuous Sweep tone (press-drag). Mixed **before** PEQ so Bypass A/B applies to the tone.
    func setSweepToneLevelDB(_ db: Double) {
        sweep.setLevelDB(db)
    }

    func beginSweepTone(frequencyHz: Double) {
        guard isRunning else { return }
        // The oscillator has its own lock; the tone starts now. Engine start / stop run on
        // `queue` asynchronously so the graph press never waits on Core Audio.
        sweep.press(atHz: frequencyHz)
        queue.async { [self] in
            // Start even if a quick click was already released — endSweepTone's queued block
            // runs after this one and keeps the tone audible briefly.
            sweepGesture &+= 1
            guard runningFlag else { return }
            // Aggregate IO only schedules while a tapped app (Music) is active. When it
            // is warm, Sweep mixes into that path. When cold, spin up a short-lived DAC
            // engine — never leave it running after the gesture (blocks Music/PT).
            if !aggregateIOIsWarmLocked(),
               dacWakeEngine?.isRunning != true,
               outputDeviceID != kAudioObjectUnknown {
                startDACSweepEngineLocked(deviceID: outputDeviceID)
            }
        }
    }

    func updateSweepTone(frequencyHz: Double) {
        sweep.updateFrequency(atHz: frequencyHz)
    }

    func endSweepTone() {
        queue.async { [self] in
            // Ordered after a queued engine start: a quick click still sounds for at least
            // `minimumAudibleSweep` once the cold DAC engine is up.
            let gesture = sweepGesture
            let remaining = dacWakeEngine == nil
                ? 0
                : Self.minimumAudibleSweep - Date().timeIntervalSince(dacWakeStartedAt)
            guard remaining > 0 else {
                sweep.release()
                stopDACSweepEngineLocked()
                return
            }
            queue.asyncAfter(deadline: .now() + remaining) { [self] in
                // A new press meanwhile owns the tone and the engine now.
                guard gesture == sweepGesture else { return }
                sweep.release()
                stopDACSweepEngineLocked()
            }
        }
    }

    func hardMuteSweepTone() {
        sweep.hardMute()
        queue.async { [self] in stopDACSweepEngineLocked() }
    }

    var isSweepToneAudible: Bool { sweep.isAudible }

    /// Diagnostics for sweep smoke: aggregate IOProc activity.
    func ioCallbackCountsForAutomation() -> (rawAggregate: UInt64, rendered: UInt64) {
        queue.sync {
            meterLock.lock()
            let rendered = meter.renderCallbacks
            meterLock.unlock()
            return (rawIOCallbackCount, rendered)
        }
    }

    func isDACSweepEngineRunningForAutomation() -> Bool {
        queue.sync {
            guard let engine = dacWakeEngine else { return false }
            return engine.isRunning
        }
    }

    /// True when the live graph’s rate differs from the DAC’s current nominal rate.
    func graphMismatchesDAC(sampleRate: Double) -> Bool {
        let graphRate = graphSampleRate
        guard graphRate > 0, sampleRate > 0 else { return false }
        return abs(graphRate - sampleRate) >= 1.0
    }

    func currentMeter() -> PassThroughMeter {
        meterLock.lock(); defer { meterLock.unlock() }
        var snap = meter
        if Date() > peakDecayDeadline {
            snap.capturePeakRMS *= 0.5
            meter.capturePeakRMS = snap.capturePeakRMS
        }
        return snap
    }

    func start(outputDeviceID: AudioDeviceID, outputDeviceUID: String) throws {
        try queue.sync { try startLocked(outputDeviceID: outputDeviceID, outputUID: outputDeviceUID) }
    }

    func stop() { queue.sync { stopLocked() } }

    func playTestToneToDAC(frequencyHz: Double = 880, durationSeconds: Double = 0.45, amplitude: Float = 0.18) throws {
        try queue.sync {
            guard runningFlag else { throw PassThroughError.engine("Pass-through bridge is not running.") }
            let rate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
            let frames = Int(rate * durationSeconds)
            let ch = max(channelCount, 1)
            var channels = Array(repeating: [Float](repeating: 0, count: frames), count: ch)
            let twoPiF = 2.0 * Double.pi * frequencyHz / rate
            for i in 0..<frames {
                let sample = amplitude * Float(sin(twoPiF * Double(i)))
                for c in 0..<ch { channels[c][i] = sample }
            }
            toneLock.lock()
            toneRemaining = channels
            toneFrameIndex = 0
            toneLock.unlock()
            log.info("Test tone queued into DAC mix (does not affect tap Signal meter)")
        }
    }

    // MARK: - Locked

    private func startLocked(outputDeviceID: AudioDeviceID, outputUID: String? = nil) throws {
        stopLocked()

        guard #available(macOS 14.2, *) else { throw PassThroughError.unsupportedOS }
        guard outputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingDAC }
        let uid = outputUID ?? Self.deviceUID(outputDeviceID)
        guard let uid, !uid.isEmpty else {
            throw PassThroughError.engine("Pinned DAC has no device UID.")
        }

        // Exclude our own process so the tap does not feedback on our DAC playback.
        var exclude: [AudioObjectID] = []
        if let selfObject = try? Self.processObjectID(forPID: getpid()) {
            exclude.append(selfObject)
        }

        let description = CATapDescription(
            excludingProcesses: exclude,
            deviceUID: uid,
            stream: 0
        )
        description.name = "HiFi Companion Pass-through"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tap)
        guard tapStatus == noErr, tap != kAudioObjectUnknown else {
            if tapStatus == kAudioHardwareNotRunningError
                || tapStatus == Int32(bitPattern: 0x6E6F7065) /* 'nope' */
                || tapStatus == -1 {
                throw PassThroughError.tapPermissionDenied
            }
            // TCC denial often surfaces as a generic failure — still hint Settings.
            if tapStatus != noErr {
                log.error("AudioHardwareCreateProcessTap status=\(tapStatus, privacy: .public)")
                throw PassThroughError.tap(tapStatus, "creating process tap (check System Audio Recording permission)")
            }
            throw PassThroughError.tapPermissionDenied
        }
        tapID = tap

        guard let tapUIDString = Self.tapUID(tap) else {
            stopLocked()
            throw PassThroughError.engine("Process tap has no UID.")
        }

        var formatASBD = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let formatStatus = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &formatASBD)
        guard formatStatus == noErr, formatASBD.mSampleRate > 0, formatASBD.mChannelsPerFrame > 0 else {
            stopLocked()
            throw PassThroughError.tap(formatStatus, "reading tap format")
        }
        let isFloat = (formatASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (formatASBD.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard isFloat, formatASBD.mBitsPerChannel == 32 else {
            stopLocked()
            throw PassThroughError.engine(
                "Process tap format is not Float32 (flags=\(formatASBD.mFormatFlags) bits=\(formatASBD.mBitsPerChannel))."
            )
        }
        asbd = formatASBD
        channelCount = Int(formatASBD.mChannelsPerFrame)
        openedSampleRate = formatASBD.mSampleRate
        log.info("Tap format \(formatASBD.mSampleRate, privacy: .public)Hz ch=\(self.channelCount, privacy: .public) nonInterleaved=\(isNonInterleaved, privacy: .public)")

        // Rebuild PEQ sections at the new rate; band/output state is owned by AppModel and re-pushed.
        peq.configure(sampleRate: formatASBD.mSampleRate, channelCount: channelCount)
        peq.resetState(channelCount: channelCount)
        sweep.configure(sampleRate: formatASBD.mSampleRate)
        sweep.hardMute()

        let aggregateUID = UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HiFiCompanionProcessTap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUIDString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard aggStatus == noErr, aggregate != kAudioObjectUnknown else {
            stopLocked()
            throw PassThroughError.tap(aggStatus, "creating private aggregate for tap+DAC")
        }
        aggregateID = aggregate

        // Use Core Audio's internal queue (nil). Targeting our control `queue` deadlocks:
        // start() runs inside queue.sync while AudioDeviceStart needs the IOProc to run.
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { [weak self] _, inInput, _, outOutput, _ in
            guard let self else { return }
            self.rawIOCallbackCount &+= 1
            self.render(input: inInput, output: outOutput)
        }
        guard ioStatus == noErr, let procID else {
            stopLocked()
            throw PassThroughError.tap(ioStatus, "creating IOProc")
        }
        ioProcID = procID

        // Start *this* IOProc only. `AudioDeviceStart(aggregate, nil)` was tried for
        // Sweep-without-Music and left Music→tap silent under `mutedWhenTapped`.
        let startStatus = AudioDeviceStart(aggregate, procID)
        guard startStatus == noErr else {
            stopLocked()
            // Permission prompt denial often fails at start.
            if startStatus == kAudioHardwareNotRunningError || startStatus == Int32(bitPattern: 0x6E6F7065) {
                throw PassThroughError.tapPermissionDenied
            }
            throw PassThroughError.tap(startStatus, "starting aggregate IO (System Audio Recording permission?)")
        }

        self.outputDeviceID = outputDeviceID
        // Do not start the DAC sweep engine here — an always-on engine on the pinned
        // DAC steals/contends with aggregate → Music silence while PT is on. Sweep
        // starts it on demand in `beginSweepTone` and tears it down on release.
        lastAggregateRenderHostTime = 0
        meterLock.lock()
        meter = PassThroughMeter(outputDeviceID: outputDeviceID, sampleRate: formatASBD.mSampleRate)
        meterLock.unlock()
        runningFlag = true
        publishStateLocked()
        log.info("Process-tap Pass-through running → DAC \(outputDeviceID, privacy: .public) @ \(formatASBD.mSampleRate, privacy: .public)Hz")
    }

    /// True when the aggregate IOProc has fired recently (Music / other tap clients).
    private func aggregateIOIsWarmLocked() -> Bool {
        guard lastAggregateRenderHostTime > 0 else { return false }
        let now = mach_absolute_time()
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            return rawIOCallbackCount > 0
        }
        let deltaTicks = now &- lastAggregateRenderHostTime
        let deltaNs = deltaTicks * UInt64(info.numer) / UInt64(info.denom)
        return deltaNs < 500_000_000 // 0.5 s
    }

    /// Direct-to-DAC engine for Sweep while aggregate IO is cold. Audible because we
    /// exclude our PID from the process tap; stop as soon as Sweep ends.
    private func startDACSweepEngineLocked(deviceID: AudioDeviceID) {
        stopDACSweepEngineLocked()
        let engine = AVAudioEngine()
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channels = max(AVAudioChannelCount(channelCount), 2)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            log.error("DAC sweep engine format failed")
            return
        }
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self else { return noErr }
            self.renderEngineSweep(
                frameCount: Int(frameCount),
                audioBufferList: audioBufferList,
                channelCount: Int(channels)
            )
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        if let au = engine.outputNode.audioUnit {
            var id = deviceID
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let st = AudioUnitSetProperty(
                au,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                size
            )
            if st != noErr {
                log.error("DAC sweep engine set device failed status=\(st, privacy: .public)")
            }
        }

        do {
            try engine.start()
            dacWakeStartedAt = Date()
            dacWakeEngine = engine
            dacWakeSource = source
            log.info("DAC sweep engine started on \(deviceID, privacy: .public)")
        } catch {
            log.error("DAC sweep engine start failed \(error.localizedDescription, privacy: .public)")
            engine.stop()
            dacWakeEngine = nil
            dacWakeSource = nil
        }
    }

    /// Realtime-safe: write Sweep (+ PEQ) into the non-interleaved engine buffer.
    private func renderEngineSweep(
        frameCount: Int,
        audioBufferList: UnsafeMutablePointer<AudioBufferList>,
        channelCount: Int
    ) {
        let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buf in abl {
            if let data = buf.mData {
                memset(data, 0, Int(buf.mDataByteSize))
            }
        }
        guard frameCount > 0, sweep.isAudible else { return }
        if engineSweepScratch.count < frameCount {
            engineSweepScratch = [Float](repeating: 0, count: max(frameCount, 512))
        }
        engineSweepScratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            sweep.renderMono(base, frames: frameCount)
        }
        let ch = min(channelCount, abl.count)
        for c in 0..<ch {
            guard let out = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frameCount {
                out[i] = engineSweepScratch[i]
            }
            peq.processChannel(out, frames: frameCount, channel: c)
        }
    }

    private func stopDACSweepEngineLocked() {
        // Tear down fully so the aggregate can reclaim the DAC for Music/PT.
        // A lingering engine client on the same device silences mutedWhenTapped playback.
        if let engine = dacWakeEngine {
            engine.stop()
            engine.reset()
            if let source = dacWakeSource {
                engine.disconnectNodeOutput(source)
                engine.detach(source)
            }
        }
        dacWakeEngine = nil
        dacWakeSource = nil
        engineSweepScratch = []
    }

    private func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        // Music path: require tap input. Aggregate IO only schedules while a tapped
        // app is active; Sweep-without-Music uses the on-demand DAC engine instead.
        // Do not memset/return-on-nil-input — that zeros the DAC while
        // `mutedWhenTapped` has already silenced the app's direct output.
        guard let input, let output else { return }
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        guard let first = inABL.first, first.mData != nil, first.mDataByteSize > 0 else { return }

        lastAggregateRenderHostTime = mach_absolute_time()

        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let n: Int
        if interleaved {
            let ch = max(Int(asbd.mChannelsPerFrame), 1)
            n = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        } else {
            n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        }
        guard n > 0 else { return }

        // --- Meter from TAP input only (never test tone / Sweep) ---
        let peak = Self.rmsPeak(abl: inABL, frames: n, interleaved: interleaved, channels: channelCount)
        meterLock.lock()
        meter.captureCallbacks &+= 1
        meter.renderCallbacks &+= 1
        if peak >= meter.capturePeakRMS { meter.capturePeakRMS = peak }
        if peak >= 0.004 {
            peakDecayDeadline = Date().addingTimeInterval(1.6)
        }
        meterLock.unlock()

        // --- Copy tap → output (same layout), then Sweep / test tone, then PEQ ---
        let copyCount = min(inABL.count, outABL.count)
        for c in 0..<copyCount {
            guard let inData = inABL[c].mData, let outData = outABL[c].mData else { continue }
            let bytes = min(Int(inABL[c].mDataByteSize), Int(outABL[c].mDataByteSize))
            memcpy(outData, inData, bytes)
            if Int(outABL[c].mDataByteSize) > bytes {
                memset(outData.advanced(by: bytes), 0, Int(outABL[c].mDataByteSize) - bytes)
            }
        }
        for c in copyCount..<outABL.count {
            if let outData = outABL[c].mData {
                memset(outData, 0, Int(outABL[c].mDataByteSize))
            }
        }

        // When aggregate is warm, Sweep mixes here (DAC engine stays down).
        mixSweepTone(into: outABL, frames: n, interleaved: interleaved)
        mixTestTone(into: outABL, frames: n, interleaved: interleaved)
        applyPEQInPlace(outABL: outABL, frames: n, interleaved: interleaved)
    }

    private func mixSweepTone(into outABL: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool) {
        // When the on-demand DAC engine is live it owns Sweep — avoid doubling.
        guard dacWakeEngine == nil else { return }
        guard frames > 0, sweep.isAudible else { return }
        if sweepScratch.count < frames {
            sweepScratch = [Float](repeating: 0, count: max(frames, 512))
        }
        sweepScratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            sweep.renderMono(base, frames: frames)
        }
        if interleaved {
            guard let out = outABL.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = channelCount
            for i in 0..<frames {
                let s = sweepScratch[i]
                if abs(s) < 1e-8 { continue }
                for c in 0..<ch {
                    out[i * ch + c] += s
                }
            }
            return
        }
        for c in 0..<min(channelCount, outABL.count) {
            guard let out = outABL[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<frames {
                let s = sweepScratch[i]
                if abs(s) < 1e-8 { continue }
                out[i] += s
            }
        }
    }

    private func applyPEQInPlace(outABL: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool) {
        if interleaved {
            guard let samples = outABL.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            peq.processInterleaved(samples, frames: frames, channels: channelCount)
            return
        }
        for c in 0..<min(channelCount, outABL.count) {
            guard let samples = outABL[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            peq.processChannel(samples, frames: frames, channel: c)
        }
    }

    private func mixTestTone(into outABL: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool) {
        toneLock.lock()
        defer { toneLock.unlock() }
        guard !toneRemaining.isEmpty, toneFrameIndex < (toneRemaining.first?.count ?? 0) else {
            toneRemaining = []
            toneFrameIndex = 0
            return
        }
        let available = (toneRemaining.first?.count ?? 0) - toneFrameIndex
        let mixFrames = min(frames, available)
        if interleaved {
            guard let out = outABL.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = channelCount
            for i in 0..<mixFrames {
                let sample = toneRemaining[0][toneFrameIndex + i]
                for c in 0..<ch {
                    out[i * ch + c] += sample
                }
            }
        } else {
            for c in 0..<min(channelCount, outABL.count, toneRemaining.count) {
                guard let out = outABL[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                let tone = toneRemaining[c]
                for i in 0..<mixFrames {
                    out[i] += tone[toneFrameIndex + i]
                }
            }
        }
        toneFrameIndex += mixFrames
        if toneFrameIndex >= (toneRemaining.first?.count ?? 0) {
            toneRemaining = []
            toneFrameIndex = 0
        }
    }

    private func publishStateLocked() {
        stateLock.withLock {
            publishedRunning = runningFlag
            publishedSampleRate = runningFlag ? openedSampleRate : 0
            publishedOutputDeviceID = runningFlag ? outputDeviceID : AudioDeviceID(kAudioObjectUnknown)
        }
    }

    private func stopLocked() {
        let wasRunning = runningFlag
        runningFlag = false
        publishStateLocked()

        stopDACSweepEngineLocked()

        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProcID = nil
        aggregateID = kAudioObjectUnknown

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
        }
        tapID = kAudioObjectUnknown

        outputDeviceID = kAudioObjectUnknown
        openedSampleRate = 0
        lastAggregateRenderHostTime = 0
        rawIOCallbackCount = 0
        toneLock.lock(); toneRemaining = []; toneFrameIndex = 0; toneLock.unlock()
        sweep.hardMute()
        meterLock.lock(); meter = PassThroughMeter(); meterLock.unlock()
        if wasRunning { log.info("Process-tap Pass-through stopped") }
    }

    // MARK: - Helpers

    private static func rmsPeak(
        abl: UnsafeMutableAudioBufferListPointer,
        frames: Int,
        interleaved: Bool,
        channels: Int
    ) -> Float {
        guard frames > 0, !abl.isEmpty else { return 0 }
        var sum: Float = 0
        var count = 0
        if interleaved {
            guard let data = abl.first?.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            let ch = max(channels, 1)
            let total = min(frames * ch, Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size)
            for i in 0..<total {
                let s = data[i]
                sum += s * s
            }
            count = total
        } else {
            for buf in abl {
                guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = min(frames, Int(buf.mDataByteSize) / MemoryLayout<Float>.size)
                for i in 0..<n {
                    let s = data[i]
                    sum += s * s
                }
                count += n
            }
        }
        guard count > 0 else { return 0 }
        return sqrt(sum / Float(count))
    }

    private static func deviceUID(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func tapUID(_ tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &object
            )
        }
        guard status == noErr, object != kAudioObjectUnknown else {
            throw PassThroughError.engine("Could not map pid \(pid) to audio process object (\(status)).")
        }
        return object
    }
}
