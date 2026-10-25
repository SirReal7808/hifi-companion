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

    /// Human-readable OSStatus (FourCharCode when printable).
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

/// Captures PCM from a virtual loopback device and plays it on a hardware DAC.
///
/// Two engines (capture + playback). Callers should start the bridge **before** switching
/// the system default to BlackHole — setting CurrentDevice during that reconfigure returns
/// `kAudioHardwareIllegalOperationError` ('nope') and caused the “second click” kick.
final class PassThroughBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "PassThroughBridge")
    private let queue = DispatchQueue(label: "com.hificompanion.passthrough")
    private let peakingEQ = PeakingBiquad()

    private var captureEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapInstalled = false
    private var runningFlag = false

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

        // Bind HAL devices with retry — 'nope' is common while a device is reconfiguring.
        try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
        try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")

        let inputFormat = capture.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "Virtual device returned an invalid input format (rate \(inputFormat.sampleRate), ch \(inputFormat.channelCount)). If System Settings → Microphone is On, this is a device/format issue, not a blanket Input denial."
            )
        }

        let outputFormat = playback.outputNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "DAC returned an invalid output format. Is the pinned device connected and free?"
            )
        }

        peakingEQ.configure(sampleRate: inputFormat.sampleRate)
        peakingEQ.resetState(channelCount: Int(inputFormat.channelCount))

        playback.connect(playerNode, to: playback.mainMixerNode, format: inputFormat)
        playback.mainMixerNode.outputVolume = 1.0

        self.captureEngine = capture
        self.playbackEngine = playback
        self.player = playerNode
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID

        capture.inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return }
            copy.frameLength = buffer.frameLength
            if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
                let channels = Int(buffer.format.channelCount)
                let frames = Int(buffer.frameLength)
                for ch in 0..<channels {
                    memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size)
                }
            } else if let src = buffer.audioBufferList.pointee.mBuffers.mData,
                      let dst = copy.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, src, Int(buffer.audioBufferList.pointee.mBuffers.mDataByteSize))
            } else {
                return
            }

            if !self.peakingEQ.isBypassed {
                self.peakingEQ.processInPlace(copy)
            }
            self.player?.scheduleBuffer(copy, completionHandler: nil)
        }
        tapInstalled = true

        do {
            playback.prepare()
            capture.prepare()
            // Re-bind after prepare in case realize dropped the device selection.
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

        self.runningFlag = true
        log.info("Pass-through bridge running (in=\(inputDeviceID, privacy: .public) out=\(outputDeviceID, privacy: .public) \(inputFormat.sampleRate, privacy: .public)Hz→\(outputFormat.sampleRate, privacy: .public)Hz)")
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
    }

    private func stopLocked() {
        let wasRunning = runningFlag
        runningFlag = false

        if let capture = captureEngine {
            if tapInstalled {
                capture.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            if capture.isRunning {
                capture.stop()
            }
        }
        if let player, player.isPlaying {
            player.stop()
        }
        if let playback = playbackEngine, playback.isRunning {
            playback.stop()
        }

        captureEngine = nil
        playbackEngine = nil
        player = nil
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
        if wasRunning {
            log.info("Pass-through bridge stopped")
        }
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
        // 'nope' while BlackHole/default output is reconfiguring — brief retry fixes first-click silence.
        for attempt in 1...8 {
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
                return
            }
            if lastStatus == kAudioHardwareIllegalOperationError || lastStatus == kAudioHardwareNotRunningError {
                let delayMs = 25 * attempt
                usleep(useconds_t(delayMs * 1000))
                continue
            }
            break
        }
        throw PassThroughError.audioUnit(lastStatus, "setting \(role) device \(deviceID)")
    }
}
