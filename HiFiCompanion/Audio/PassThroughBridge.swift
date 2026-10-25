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
            return "Audio unit error \(status) while \(context)"
        case .engine(let message):
            return message
        }
    }
}

/// Captures PCM from a virtual loopback device and plays it on a hardware DAC.
///
/// Uses **two** AVAudioEngines (capture + playback). Binding both devices on a single
/// engine fails on current macOS when input is set before output (`-10851`), which left
/// Pass-through “on” with a silent DAC.
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

    /// Fixed test band: 1 kHz peaking, Q ≈ 1.41.
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

        // Bind each HAL on its own engine (avoids single-engine -10851 when in-then-out).
        try Self.setCurrentDevice(inputDeviceID, onIONode: capture.inputNode, role: "capture input")
        try Self.setCurrentDevice(outputDeviceID, onIONode: playback.outputNode, role: "playback output")

        let inputFormat = capture.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "Virtual device returned an invalid input format (rate \(inputFormat.sampleRate), ch \(inputFormat.channelCount)). Check Input permission and BlackHole."
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

        // Player feeds the DAC graph at the capture format; mixer/HAL convert to the DAC rate.
        playback.connect(playerNode, to: playback.mainMixerNode, format: inputFormat)
        playback.mainMixerNode.outputVolume = 1.0

        // Publish nodes before start so the tap callback never sees a nil player.
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
            try playback.start()
            playerNode.play()
            try capture.start()
        } catch {
            if tapInstalled {
                capture.inputNode.removeTap(onBus: 0)
                tapInstalled = false
            }
            capture.stop()
            playerNode.stop()
            playback.stop()
            self.captureEngine = nil
            self.playbackEngine = nil
            self.player = nil
            self.inputDeviceID = kAudioObjectUnknown
            self.outputDeviceID = kAudioObjectUnknown
            throw PassThroughError.engine("Bridge engine failed to start: \(error.localizedDescription)")
        }

        self.runningFlag = true
        log.info("Pass-through bridge running (in=\(inputDeviceID, privacy: .public) out=\(outputDeviceID, privacy: .public) \(inputFormat.sampleRate, privacy: .public)Hz→\(outputFormat.sampleRate, privacy: .public)Hz)")
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
        if let player {
            if player.isPlaying {
                player.stop()
            }
        }
        if let playback = playbackEngine {
            if playback.isRunning {
                playback.stop()
            }
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
        var id = deviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            size
        )
        guard status == noErr else {
            throw PassThroughError.audioUnit(status, "setting \(role) device \(deviceID)")
        }
    }
}
