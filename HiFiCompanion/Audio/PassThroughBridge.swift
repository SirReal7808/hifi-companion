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

struct PassThroughMeter: Equatable {
    var capturePeakRMS: Float = 0
    var captureCallbacks: UInt64 = 0
    var renderCallbacks: UInt64 = 0
    var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
    var inputSampleRate: Double = 0
    var outputSampleRate: Double = 0

    var isHearingAudio: Bool { capturePeakRMS >= 0.004 }

    var menuLine: String {
        if captureCallbacks == 0 {
            return "Signal: waiting for capture…"
        }
        if isHearingAudio {
            let db = 20 * log10(max(capturePeakRMS, 1e-6))
            return String(format: "Signal: hearing audio (%.0f dBFS)", db)
        }
        return "Signal: silence (play Music into BlackHole)"
    }
}

/// BlackHole capture → ring buffer → DAC `AVAudioSourceNode`.
///
/// Avoids `AVAudioPlayerNode.scheduleBuffer` from the input-tap realtime thread (works for
/// short tones, drops continuous Music/YouTube). Playback device is pinned explicitly so a
/// default-output switch cannot remap the DAC leg onto BlackHole.
final class PassThroughBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "PassThroughBridge")
    private let queue = DispatchQueue(label: "com.hificompanion.passthrough")
    private let peakingEQ = PeakingBiquad()
    private let meterLock = NSLock()

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var ring: PCMRingBuffer?
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var runningFlag = false
    private var meter = PassThroughMeter()
    private var peakDecayDeadline = Date.distantPast
    private var outputFormat: AVAudioFormat?

    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    var testEQFrequencyHz: Double { PeakingBiquad.defaultFrequency }
    var testEQQ: Double { PeakingBiquad.defaultQ }

    var isRunning: Bool { queue.sync { runningFlag } }
    var isEQBypassed: Bool { peakingEQ.isBypassed }
    var eqGainDB: Double { peakingEQ.currentGainDB }

    func setEQGainDB(_ gainDB: Double) { peakingEQ.setGainDB(gainDB) }

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
        try queue.sync { try startLocked(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID) }
    }

    func stop() { queue.sync { stopLocked() } }

    func restartIfRunning(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        try queue.sync {
            guard runningFlag else { return }
            let gain = peakingEQ.currentGainDB
            try startLocked(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
            peakingEQ.setGainDB(gain)
        }
    }

    @discardableResult
    func ensureDeviceBinding() -> Bool {
        queue.sync {
            guard runningFlag, let capture = captureEngine, let playback = playbackEngine else { return false }
            let inOK = Self.currentDevice(on: capture.inputNode) == inputDeviceID
            let outOK = Self.currentDevice(on: playback.outputNode) == outputDeviceID
            if inOK && outOK { return true }
            log.warning("Bridge device drift in=\(Self.currentDevice(on: capture.inputNode), privacy: .public) out=\(Self.currentDevice(on: playback.outputNode), privacy: .public); rebinding")
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
            guard let buffer = Self.makeTone(format: format, frames: frames, frequencyHz: frequencyHz, amplitude: amplitude) else {
                throw PassThroughError.engine("Inject-tone buffer alloc failed.")
            }
            let sem = DispatchSemaphore(value: 0)
            node.scheduleBuffer(buffer) { sem.signal() }
            _ = sem.wait(timeout: .now() + durationSeconds + 0.5)
            node.stop()
            gen.stop()
        }
    }

    func playTestToneToDAC(frequencyHz: Double = 880, durationSeconds: Double = 0.45, amplitude: Float = 0.18) throws {
        try queue.sync {
            guard runningFlag, let ring, let format = outputFormat else {
                throw PassThroughError.engine("Pass-through bridge is not running.")
            }
            if let playback = playbackEngine {
                try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")
            }
            let frames = Int(format.sampleRate * durationSeconds)
            guard let buffer = Self.makeTone(
                format: format,
                frames: AVAudioFrameCount(frames),
                frequencyHz: frequencyHz,
                amplitude: amplitude
            ), let channels = buffer.floatChannelData else {
                throw PassThroughError.engine("Could not allocate test-tone buffer.")
            }
            // Mix tone into the ring so it shares the live DAC path with capture.
            ring.write(nonInterleaved: channels, frames: frames, channelCount: Int(format.channelCount))
            log.info("Test tone mixed into DAC ring (device \(self.outputDeviceID, privacy: .public))")
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

        try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
        try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")

        if #available(macOS 13.0, *) {
            try? capture.inputNode.setVoiceProcessingEnabled(false)
        }

        let inputFormat = capture.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "Virtual device returned an invalid input format (rate \(inputFormat.sampleRate), ch \(inputFormat.channelCount))."
            )
        }
        let outFormat = playback.outputNode.outputFormat(forBus: 0)
        guard outFormat.sampleRate > 0, outFormat.channelCount > 0 else {
            throw PassThroughError.engine("DAC returned an invalid output format.")
        }

        let boundIn = Self.currentDevice(on: capture.inputNode)
        let boundOut = Self.currentDevice(on: playback.outputNode)
        guard boundIn == inputDeviceID else {
            throw PassThroughError.engine("Capture bound to device \(boundIn) instead of BlackHole \(inputDeviceID).")
        }
        guard boundOut == outputDeviceID else {
            throw PassThroughError.engine("Playback bound to device \(boundOut) instead of DAC \(outputDeviceID).")
        }

        peakingEQ.configure(sampleRate: outFormat.sampleRate)
        peakingEQ.resetState(channelCount: Int(outFormat.channelCount))

        let ringBuffer = PCMRingBuffer(
            capacityFrames: Int(outFormat.sampleRate * 0.75),
            channels: Int(outFormat.channelCount)
        )
        let needsConvert =
            abs(inputFormat.sampleRate - outFormat.sampleRate) > 0.5
            || inputFormat.channelCount != outFormat.channelCount
        let formatConverter = needsConvert ? AVAudioConverter(from: inputFormat, to: outFormat) : nil
        if needsConvert && formatConverter == nil {
            throw PassThroughError.engine(
                "No converter for \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch → \(outFormat.sampleRate)Hz/\(outFormat.channelCount)ch."
            )
        }

        let eq = peakingEQ
        let meterBox = meterLock
        weak var weakSelf = self

        let source = AVAudioSourceNode(format: outFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let ring = weakSelf?.ring else {
                for buf in abl {
                    if let data = buf.mData { memset(data, 0, Int(buf.mDataByteSize)) }
                }
                return noErr
            }
            _ = ring.read(into: abl, frames: Int(frameCount))

            // Optional EQ on the render buffer.
            if !eq.isBypassed, let first = abl.first?.mData?.assumingMemoryBound(to: Float.self) {
                // Build a temporary PCM buffer view when possible.
                if let tmp = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: frameCount) {
                    tmp.frameLength = frameCount
                    if let dst = tmp.floatChannelData {
                        for c in 0..<min(Int(outFormat.channelCount), abl.count) {
                            if let src = abl[c].mData?.assumingMemoryBound(to: Float.self) {
                                memcpy(dst[c], src, Int(frameCount) * MemoryLayout<Float>.size)
                            }
                        }
                        eq.processInPlace(tmp)
                        for c in 0..<min(Int(outFormat.channelCount), abl.count) {
                            if let dstBuf = abl[c].mData?.assumingMemoryBound(to: Float.self) {
                                memcpy(dstBuf, dst[c], Int(frameCount) * MemoryLayout<Float>.size)
                            }
                        }
                    }
                }
            }

            meterBox.lock()
            if var m = weakSelf?.meter {
                m.renderCallbacks &+= 1
                weakSelf?.meter = m
            }
            meterBox.unlock()
            return noErr
        }

        playback.attach(source)
        playback.connect(source, to: playback.mainMixerNode, format: outFormat)
        playback.mainMixerNode.outputVolume = 1.0

        self.captureEngine = capture
        self.playbackEngine = playback
        self.sourceNode = source
        self.ring = ringBuffer
        self.converter = formatConverter
        self.outputFormat = outFormat
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID

        meterLock.lock()
        meter = PassThroughMeter(
            inputDeviceID: inputDeviceID,
            outputDeviceID: outputDeviceID,
            inputSampleRate: inputFormat.sampleRate,
            outputSampleRate: outFormat.sampleRate
        )
        meterLock.unlock()

        // Tap only feeds the ring — never schedule on a player from the realtime thread.
        capture.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleCaptureBuffer(buffer, inputFormat: inputFormat, outputFormat: outFormat)
        }
        tapInstalled = true

        do {
            playback.prepare()
            capture.prepare()
            try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
            try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")
            try playback.start()
            try capture.start()
        } catch let error as PassThroughError {
            tearDownPartial(capture: capture, playback: playback, source: source)
            throw error
        } catch {
            tearDownPartial(capture: capture, playback: playback, source: source)
            throw PassThroughError.engine("Bridge engine failed to start: \(error.localizedDescription)")
        }

        let liveIn = Self.currentDevice(on: capture.inputNode)
        let liveOut = Self.currentDevice(on: playback.outputNode)
        guard liveIn == inputDeviceID, liveOut == outputDeviceID else {
            tearDownPartial(capture: capture, playback: playback, source: source)
            throw PassThroughError.engine(
                "Bridge devices drifted after start (in=\(liveIn) out=\(liveOut); want in=\(inputDeviceID) out=\(outputDeviceID))."
            )
        }

        runningFlag = true
        log.info("Pass-through ring-bridge in=\(inputDeviceID, privacy: .public)@\(inputFormat.sampleRate, privacy: .public) → out=\(outputDeviceID, privacy: .public)@\(outFormat.sampleRate, privacy: .public)")
    }

    private func handleCaptureBuffer(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        let peak = Self.rmsPeak(buffer)
        meterLock.lock()
        meter.captureCallbacks &+= 1
        if peak >= meter.capturePeakRMS {
            meter.capturePeakRMS = peak
        }
        if peak >= 0.004 {
            // Keep "hearing audio" sticky while Music is playing (avoid flicker between buffers).
            peakDecayDeadline = Date().addingTimeInterval(1.6)
        }
        meterLock.unlock()

        guard let ring else { return }

        let playBuffer: AVAudioPCMBuffer
        if let converter {
            converter.reset()
            let ratio = outputFormat.sampleRate / max(buffer.format.sampleRate, 1)
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: max(capacity, 1)) else { return }
            var error: NSError?
            var provided = false
            let status = converter.convert(to: converted, error: &error) { _, st in
                if provided { st.pointee = .noDataNow; return nil }
                provided = true
                st.pointee = .haveData
                return buffer
            }
            guard error == nil, status != .error, converted.frameLength > 0 else { return }
            playBuffer = converted
        } else if let channels = buffer.floatChannelData {
            // Same rate/channels — write directly from tap buffer.
            ring.write(
                nonInterleaved: channels,
                frames: Int(buffer.frameLength),
                channelCount: Int(buffer.format.channelCount)
            )
            return
        } else {
            return
        }

        if let channels = playBuffer.floatChannelData {
            ring.write(
                nonInterleaved: channels,
                frames: Int(playBuffer.frameLength),
                channelCount: Int(playBuffer.format.channelCount)
            )
        }
    }

    private func tearDownPartial(capture: AVAudioEngine, playback: AVAudioEngine, source: AVAudioSourceNode) {
        if tapInstalled {
            capture.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        capture.stop()
        playback.stop()
        playback.detach(source)
        captureEngine = nil
        playbackEngine = nil
        sourceNode = nil
        ring = nil
        converter = nil
        outputFormat = nil
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
        if let playback = playbackEngine {
            if playback.isRunning { playback.stop() }
            if let sourceNode {
                playback.detach(sourceNode)
            }
        }
        captureEngine = nil
        playbackEngine = nil
        sourceNode = nil
        ring?.reset()
        ring = nil
        converter = nil
        outputFormat = nil
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
        meterLock.lock(); meter = PassThroughMeter(); meterLock.unlock()
        if wasRunning { log.info("Pass-through bridge stopped") }
    }

    private static func makeTone(format: AVAudioFormat, frames: AVAudioFrameCount, frequencyHz: Double, amplitude: Float) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let twoPiF = 2.0 * Double.pi * frequencyHz / format.sampleRate
        guard let channels = buffer.floatChannelData else { return buffer }
        for i in 0..<Int(frames) {
            let sample = amplitude * Float(sin(twoPiF * Double(i)))
            for ch in 0..<Int(format.channelCount) {
                channels[ch][i] = sample
            }
        }
        return buffer
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
            if lastStatus == noErr, currentDevice(on: node) == deviceID {
                return
            }
            if lastStatus == noErr
                || lastStatus == kAudioHardwareIllegalOperationError
                || lastStatus == kAudioHardwareNotRunningError {
                usleep(useconds_t(30_000 * attempt))
                continue
            }
            break
        }
        throw PassThroughError.audioUnit(lastStatus, "setting \(role) device \(deviceID)")
    }
}
