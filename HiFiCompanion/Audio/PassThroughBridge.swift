import AVFoundation
import CoreAudio
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
            return "Pin a hardware DAC before enabling Pass-through."
        case .unsupportedOS:
            return "Process-tap Pass-through requires macOS 14.2 or later."
        case .tapPermissionDenied:
            return "System Audio Recording access denied. System Settings → Privacy & Security → Screen & System Audio Recording (or System Audio) → enable HiFi Companion, then try Pass-through again."
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
    private let peakingEQ = PeakingBiquad()
    private let meterLock = NSLock()
    private let toneLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var runningFlag = false
    private var meter = PassThroughMeter()
    private var peakDecayDeadline = Date.distantPast
    private var asbd = AudioStreamBasicDescription()
    private var channelCount: Int = 2
    /// Sample rate the tap/aggregate was opened at (for SB-change rebuild detection).
    private var openedSampleRate: Double = 0

    /// Pending test-tone samples (non-interleaved planar scratch), mixed only into **output**.
    private var toneRemaining: [[Float]] = []
    private var toneFrameIndex = 0

    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    /// Kept for UI/status compatibility; process tap has no BlackHole input device.
    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown

    var testEQFrequencyHz: Double { PeakingBiquad.defaultFrequency }
    var testEQQ: Double { PeakingBiquad.defaultQ }
    var isRunning: Bool { queue.sync { runningFlag } }
    var isEQBypassed: Bool { peakingEQ.isBypassed }
    var eqGainDB: Double { peakingEQ.currentGainDB }
    /// Rate the live tap graph was built for; 0 if not running.
    var graphSampleRate: Double { queue.sync { runningFlag ? openedSampleRate : 0 } }

    func setEQGainDB(_ gainDB: Double) { peakingEQ.setGainDB(gainDB) }

    /// Automation: analytical magnitude of the live biquad (proves coeffs, not a tone bypass).
    func eqMagnitudeDBForAutomation(atHz: Double) -> Double {
        peakingEQ.magnitudeDB(atHz: atHz)
    }

    /// True when the live graph’s rate differs from the DAC’s current nominal rate.
    func graphMismatchesDAC(sampleRate: Double) -> Bool {
        queue.sync {
            guard runningFlag, openedSampleRate > 0, sampleRate > 0 else { return false }
            return abs(openedSampleRate - sampleRate) >= 1.0
        }
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

    /// `inputDeviceID` ignored (legacy BlackHole API); only `outputDeviceID` (pinned DAC) is used.
    func start(inputDeviceID _: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        try queue.sync { try startLocked(outputDeviceID: outputDeviceID) }
    }

    func start(outputDeviceID: AudioDeviceID, outputDeviceUID: String) throws {
        try queue.sync { try startLocked(outputDeviceID: outputDeviceID, outputUID: outputDeviceUID) }
    }

    func stop() { queue.sync { stopLocked() } }

    func restartIfRunning(inputDeviceID _: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        try queue.sync {
            guard runningFlag else { return }
            let gain = peakingEQ.currentGainDB
            let uid = Self.deviceUID(outputDeviceID) ?? ""
            try startLocked(outputDeviceID: outputDeviceID, outputUID: uid)
            peakingEQ.setGainDB(gain)
        }
    }

    @discardableResult
    func ensureDeviceBinding() -> Bool {
        // Process-tap aggregate owns the DAC subdevice; nothing to re-bind like AVAudioEngine.
        queue.sync { runningFlag }
    }

    func injectToneIntoCaptureDevice(frequencyHz: Double = 440, durationSeconds: Double = 0.55, amplitude: Float = 0.22) throws {
        // No BlackHole inject — test tone goes to the DAC mix only (does not affect tap RMS).
        try playTestToneToDAC(frequencyHz: frequencyHz, durationSeconds: durationSeconds, amplitude: amplitude)
    }

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

        // Recompute biquad coeffs for this rate; preserve current gain (Test EQ stays live).
        let keepGain = peakingEQ.currentGainDB
        peakingEQ.configure(sampleRate: formatASBD.mSampleRate)
        peakingEQ.setGainDB(keepGain)
        peakingEQ.resetState(channelCount: channelCount)

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
            self?.render(input: inInput, output: outOutput)
        }
        guard ioStatus == noErr, let procID else {
            stopLocked()
            throw PassThroughError.tap(ioStatus, "creating IOProc")
        }
        ioProcID = procID

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
        self.inputDeviceID = kAudioObjectUnknown
        meterLock.lock()
        meter = PassThroughMeter(outputDeviceID: outputDeviceID, sampleRate: formatASBD.mSampleRate)
        meterLock.unlock()
        runningFlag = true
        log.info("Process-tap Pass-through running → DAC \(outputDeviceID, privacy: .public) @ \(formatASBD.mSampleRate, privacy: .public)Hz")
    }

    private func render(
        input: UnsafePointer<AudioBufferList>?,
        output: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let input, let output else { return }
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        guard let first = inABL.first, first.mData != nil else { return }

        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        let n: Int
        if interleaved {
            let ch = max(Int(asbd.mChannelsPerFrame), 1)
            n = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * ch)
        } else {
            n = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        }
        guard n > 0 else { return }

        // --- Meter from TAP input only (never test tone) ---
        let peak = Self.rmsPeak(abl: inABL, frames: n, interleaved: interleaved, channels: channelCount)
        meterLock.lock()
        meter.captureCallbacks &+= 1
        meter.renderCallbacks &+= 1
        if peak >= meter.capturePeakRMS { meter.capturePeakRMS = peak }
        if peak >= 0.004 {
            peakDecayDeadline = Date().addingTimeInterval(1.6)
        }
        meterLock.unlock()

        // --- Copy tap → output (same layout), then EQ, then mix test tone ---
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

        // Test EQ on the tap→DAC path (before tone mix). No heap alloc in the IOProc.
        if !peakingEQ.isBypassed {
            applyEQInPlace(outABL: outABL, frames: n, interleaved: interleaved)
        }

        mixTestTone(into: outABL, frames: n, interleaved: interleaved)
    }

    private func applyEQInPlace(outABL: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool) {
        if interleaved {
            guard let samples = outABL.first?.mData?.assumingMemoryBound(to: Float.self) else { return }
            peakingEQ.processInterleaved(samples, frames: frames, channels: channelCount)
            return
        }
        for c in 0..<min(channelCount, outABL.count) {
            guard let samples = outABL[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
            peakingEQ.processChannel(samples, frames: frames, channel: c)
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

    private func stopLocked() {
        let wasRunning = runningFlag
        runningFlag = false

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
        inputDeviceID = kAudioObjectUnknown
        openedSampleRate = 0
        toneLock.lock(); toneRemaining = []; toneFrameIndex = 0; toneLock.unlock()
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
