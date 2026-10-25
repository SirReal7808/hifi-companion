import AVFoundation
import CoreAudio
import Foundation
import os.log

enum PassThroughError: LocalizedError {
    case missingVirtualDevice
    case missingDAC
    case microphoneDenied
    case audioUnit(OSStatus, String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .missingVirtualDevice:
            return "Virtual device not found. Install BlackHole 2ch (see README)."
        case .missingDAC:
            return "Pin a hardware DAC before enabling Pass-through."
        case .microphoneDenied:
            return MicrophoneAccess.settingsHelp
        case .audioUnit(let status, let context):
            return "Audio unit error \(Self.describe(status)) while \(context)"
        case .engine(let message):
            return message
        }
    }

    static func describe(_ status: OSStatus) -> String {
        if status == noErr { return "noErr" }
        if status == kAudioHardwareIllegalOperationError {
            return "\(status) (kAudioHardwareIllegalOperationError/'nope' — device busy or reconfiguring)"
        }
        if status == kAudioHardwareBadDeviceError {
            return "\(status) (kAudioHardwareBadDeviceError/'!dev')"
        }
        if status == kAudioHardwareNotRunningError {
            return "\(status) (kAudioHardwareNotRunningError)"
        }
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

/// Live hop stats for the menu meter / smoke tests.
struct PassThroughMeter: Equatable {
    var capturePeakRMS: Float = 0
    var captureCallbacks: UInt64 = 0
    var scheduledBuffers: UInt64 = 0
    var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    var inputSampleRate: Double = 0
    var outputSampleRate: Double = 0

    /// True when recent capture carries audible energy.
    var isHearingAudio: Bool { capturePeakRMS >= 0.004 }

    var menuLine: String {
        if captureCallbacks == 0 {
            return "Signal: waiting for capture…"
        }
        if isHearingAudio {
            let db = 20 * log10(max(capturePeakRMS, 1e-6))
            return String(format: "Signal: hearing audio (%.0f dBFS)", db)
        }
        return "Signal: silence (play Music / use Test tone)"
    }
}

/// Captures PCM from BlackHole and plays it on a hardware DAC.
///
/// **Ordering:** Caller must set the system default to BlackHole *before* `start`, then settle.
/// Starting first and switching default afterward makes AVAudioEngine remap the playback
/// AU onto BlackHole (silent DAC). Two engines keep capture/playback on explicit devices.
final class PassThroughBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "PassThroughBridge")
    private let queue = DispatchQueue(label: "com.hificompanion.passthrough")
    private let peakingEQ = PeakingBiquad()
    private let meterLock = NSLock()

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapInstalled = false
    private var runningFlag = false
    private var meter = PassThroughMeter()
    private var peakDecayDeadline = Date.distantPast

    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    var testEQFrequencyHz: Double { PeakingBiquad.defaultFrequency }
    var testEQQ: Double { PeakingBiquad.defaultQ }

    var isRunning: Bool {
        queue.sync { runningFlag }
    }

    var isEQBypassed: Bool { peakingEQ.isBypassed }
    var eqGainDB: Double { peakingEQ.currentGainDB }

    func setEQGainDB(_ gainDB: Double) {
        peakingEQ.setGainDB(gainDB)
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

    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        try queue.sync {
            try startLocked(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    func restartIfRunning(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        try queue.sync {
            guard runningFlag else { return }
            let gain = peakingEQ.currentGainDB
            try startLocked(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
            peakingEQ.setGainDB(gain)
        }
    }

    /// Re-assert HAL device binding if Core Audio remapped us after a default-output change.
    @discardableResult
    func ensureDeviceBinding() -> Bool {
        queue.sync {
            guard runningFlag,
                  let capture = captureEngine,
                  let playback = playbackEngine
            else { return false }
            let inOK = (Self.currentDevice(on: capture.inputNode) == inputDeviceID)
            let outOK = (Self.currentDevice(on: playback.outputNode) == outputDeviceID)
            if inOK && outOK { return true }
            log.warning("Bridge device drift detected (in=\(Self.currentDevice(on: capture.inputNode), privacy: .public) out=\(Self.currentDevice(on: playback.outputNode), privacy: .public)); rebinding")
            do {
                try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
                try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")
                return Self.currentDevice(on: capture.inputNode) == inputDeviceID
                    && Self.currentDevice(on: playback.outputNode) == outputDeviceID
            } catch {
                log.error("Rebind failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
    }

    /// Play a short tone into BlackHole (system default should already be BH) so capture RMS rises.
    /// Used by smoke tests to prove the hop is non-silent end-to-end.
    func injectToneIntoCaptureDevice(frequencyHz: Double = 440, durationSeconds: Double = 0.55, amplitude: Float = 0.22) throws {
        try queue.sync {
            guard runningFlag, inputDeviceID != kAudioObjectUnknown else {
                throw PassThroughError.engine("Bridge not running; cannot inject capture tone.")
            }
            let gen = AVAudioEngine()
            let node = AVAudioPlayerNode()
            gen.attach(node)
            try Self.setCurrentDevice(inputDeviceID, onIONode: gen.outputNode, role: "tone→virtual output")
            let format = gen.outputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                throw PassThroughError.engine("Virtual output format invalid for inject tone.")
            }
            gen.connect(node, to: gen.mainMixerNode, format: format)
            gen.mainMixerNode.outputVolume = 1
            try gen.start()
            node.play()
            let frames = AVAudioFrameCount(format.sampleRate * durationSeconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw PassThroughError.engine("Inject-tone buffer alloc failed.")
            }
            buffer.frameLength = frames
            let twoPiF = 2.0 * Double.pi * frequencyHz / format.sampleRate
            if let channels = buffer.floatChannelData {
                for i in 0..<Int(frames) {
                    let sample = amplitude * Float(sin(twoPiF * Double(i)))
                    for ch in 0..<Int(format.channelCount) { channels[ch][i] = sample }
                }
            }
            let sem = DispatchSemaphore(value: 0)
            node.scheduleBuffer(buffer) { sem.signal() }
            _ = sem.wait(timeout: .now() + durationSeconds + 0.5)
            node.stop()
            gen.stop()
        }
    }

    /// Prove the DAC playback leg with a short tone (does not require BlackHole capture).
    func playTestToneToDAC(frequencyHz: Double = 880, durationSeconds: Double = 0.45, amplitude: Float = 0.18) throws {
        try queue.sync {
            guard runningFlag, let playback = playbackEngine, let player else {
                throw PassThroughError.engine("Pass-through bridge is not running.")
            }
            let format = playback.outputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw PassThroughError.engine("DAC output format invalid for test tone.")
            }
            // Ensure we are still on the DAC — not remapped to BlackHole.
            try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")
            let frames = AVAudioFrameCount(format.sampleRate * durationSeconds)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                throw PassThroughError.engine("Could not allocate test-tone buffer.")
            }
            buffer.frameLength = frames
            let twoPiF = 2.0 * Double.pi * frequencyHz / format.sampleRate
            if let channels = buffer.floatChannelData {
                for i in 0..<Int(frames) {
                    let sample = amplitude * Float(sin(twoPiF * Double(i)))
                    for ch in 0..<Int(format.channelCount) {
                        channels[ch][i] = sample
                    }
                }
            }
            if !player.isPlaying { player.play() }
            player.scheduleBuffer(buffer, completionHandler: nil)
            log.info("Test tone scheduled to DAC device \(self.outputDeviceID, privacy: .public)")
        }
    }

    // MARK: - Locked

    private func startLocked(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        stopLocked()

        guard inputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingVirtualDevice }
        guard outputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingDAC }
        guard inputDeviceID != outputDeviceID else {
            throw PassThroughError.engine("Virtual input and DAC output must be different devices (feedback loop).")
        }

        let capture = AVAudioEngine()
        let playback = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        playback.attach(playerNode)

        try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
        try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")

        let inputFormat = capture.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "Virtual device returned an invalid input format (rate \(inputFormat.sampleRate), ch \(inputFormat.channelCount))."
            )
        }

        let outputFormat = playback.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            throw PassThroughError.engine("DAC returned an invalid output format.")
        }

        // Verify bindings stuck (AVAudioEngine loves to follow the default output device).
        let boundIn = Self.currentDevice(on: capture.inputNode)
        let boundOut = Self.currentDevice(on: playback.outputNode)
        guard boundIn == inputDeviceID else {
            throw PassThroughError.engine("Capture bound to device \(boundIn) instead of BlackHole \(inputDeviceID).")
        }
        guard boundOut == outputDeviceID else {
            throw PassThroughError.engine("Playback bound to device \(boundOut) instead of DAC \(outputDeviceID) — would be silent on the DAC.")
        }

        peakingEQ.configure(sampleRate: inputFormat.sampleRate)
        peakingEQ.resetState(channelCount: Int(inputFormat.channelCount))

        // Connect player at the DAC/output format. Convert in the tap when rates/layouts differ.
        playback.connect(playerNode, to: playback.mainMixerNode, format: outputFormat)
        playback.mainMixerNode.outputVolume = 1.0
        playerNode.volume = 1.0

        let needsConvert =
            abs(inputFormat.sampleRate - outputFormat.sampleRate) > 0.5
            || inputFormat.channelCount != outputFormat.channelCount
        let converter = needsConvert ? AVAudioConverter(from: inputFormat, to: outputFormat) : nil
        if needsConvert && converter == nil {
            throw PassThroughError.engine(
                "No converter for \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch → \(outputFormat.sampleRate)Hz/\(outputFormat.channelCount)ch."
            )
        }

        self.captureEngine = capture
        self.playbackEngine = playback
        self.player = playerNode
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID

        meterLock.lock()
        meter = PassThroughMeter(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outputFormat.sampleRate
        )
        meterLock.unlock()

        capture.inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCaptureBuffer(
                buffer,
                converter: converter,
                outputFormat: outputFormat,
                player: playerNode
            )
        }
        tapInstalled = true

        do {
            playback.prepare()
            capture.prepare()
            try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
            try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")
            try playback.start()
            playerNode.play()
            try capture.start()
        } catch let error as PassThroughError {
            tearDownPartial(capture: capture, playback: playback, player: playerNode)
            throw error
        } catch {
            tearDownPartial(capture: capture, playback: playback, player: playerNode)
            throw PassThroughError.engine("Bridge engine failed to start: \(error.localizedDescription)")
        }

        // Final binding check after start.
        let liveIn = Self.currentDevice(on: capture.inputNode)
        let liveOut = Self.currentDevice(on: playback.outputNode)
        guard liveIn == inputDeviceID, liveOut == outputDeviceID else {
            tearDownPartial(capture: capture, playback: playback, player: playerNode)
            throw PassThroughError.engine(
                "Bridge devices drifted after start (in=\(liveIn) out=\(liveOut); want in=\(inputDeviceID) out=\(outputDeviceID))."
            )
        }

        self.runningFlag = true
        log.info("Pass-through bridge running in=\(inputDeviceID, privacy: .public)@\(inputFormat.sampleRate, privacy: .public) → out=\(outputDeviceID, privacy: .public)@\(outputFormat.sampleRate, privacy: .public)")
    }

    private func handleCaptureBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        outputFormat: AVAudioFormat,
        player: AVAudioPlayerNode
    ) {
        let peak = Self.rmsPeak(buffer)
        meterLock.lock()
        meter.captureCallbacks &+= 1
        if peak >= meter.capturePeakRMS {
            meter.capturePeakRMS = peak
            peakDecayDeadline = Date().addingTimeInterval(0.6)
        }
        meterLock.unlock()

        let playBuffer: AVAudioPCMBuffer
        if let converter {
            let ratio = outputFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            var provided = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if provided {
                    status.pointee = .noDataNow
                    return nil
                }
                provided = true
                status.pointee = .haveData
                return buffer
            }
            converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
            guard error == nil, converted.frameLength > 0 else { return }
            if !peakingEQ.isBypassed {
                peakingEQ.processInPlace(converted)
            }
            playBuffer = converted
        } else {
            guard let copy = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameCapacity) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                let channels = Int(min(buffer.format.channelCount, outputFormat.channelCount))
                let frames = Int(buffer.frameLength)
                for ch in 0..<channels {
                    memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
                }
            } else {
                return
            }
            if !peakingEQ.isBypassed {
                peakingEQ.processInPlace(copy)
            }
            playBuffer = copy
        }

        player.scheduleBuffer(playBuffer, completionHandler: nil)
        meterLock.lock()
        meter.scheduledBuffers &+= 1
        meterLock.unlock()
    }

    private func tearDownPartial(capture: AVAudioEngine, playback: AVAudioEngine, player: AVAudioPlayerNode) {
        if tapInstalled {
            capture.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        capture.stop()
        player.stop()
        playback.stop()
        captureEngine = nil
        playbackEngine = nil
        self.player = nil
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
        runningFlag = false
        meterLock.lock(); meter = PassThroughMeter(); meterLock.unlock()
    }

    private func stopLocked() {
        let wasRunning = runningFlag
        runningFlag = false

        if let capture = captureEngine {
            if tapInstalled {
                capture.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if capture.isRunning { capture.stop() }
        }
        if let player, player.isPlaying { player.stop() }
        if let playback = playbackEngine, playback.isRunning { playback.stop() }

        captureEngine = nil
        playbackEngine = nil
        player = nil
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
        meterLock.lock(); meter = PassThroughMeter(); meterLock.unlock()
        if wasRunning {
            log.info("Pass-through bridge stopped")
        }
    }

    private static func rmsPeak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return 0 }
        var sum: Float = 0
        for ch in 0..<channelCount {
            let samples = channels[ch]
            for i in 0..<frames {
                let s = samples[i]
                sum += s * s
            }
        }
        return sqrt(sum / Float(frames * channelCount))
    }

    private static func currentDevice(on node: AVAudioIONode) -> AudioDeviceID {
        guard let audioUnit = node.audioUnit else { return kAudioObjectUnknown }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            &size
        )
        return status == noErr ? id : kAudioObjectUnknown
    }

    private static func setCurrentDevice(
        _ deviceID: AudioDeviceID,
        onIONode node: AVAudioIONode,
        role: String
    ) throws {
        guard let audioUnit = node.audioUnit else {
            throw PassThroughError.engine("Missing AudioUnit for \(role).")
        }

        var lastStatus: OSStatus = noErr
        for attempt in 1...10 {
            var id = deviceID
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            lastStatus = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                size
            )
            if lastStatus == noErr {
                // Confirm read-back.
                if currentDevice(on: node) == deviceID { return }
                usleep(useconds_t(20_000 * attempt))
                continue
            }
            if lastStatus == kAudioHardwareIllegalOperationError || lastStatus == kAudioHardwareNotRunningError {
                usleep(useconds_t(30_000 * attempt))
                continue
            }
            break
        }
        throw PassThroughError.audioUnit(lastStatus, "setting \(role) device \(deviceID)")
    }
}
