import AVFoundation
import CoreAudio
import Foundation

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
            return "Pinned DAC not found."
        case .microphoneDenied:
            return "Input access is required to capture system audio from the virtual device."
        case .audioUnit(let status, let context):
            return "Audio unit error \(status) while \(context)"
        case .engine(let message):
            return message
        }
    }
}

/// Captures PCM from a virtual loopback device and writes to a hardware DAC.
/// Optional one-band peaking EQ runs in float when gain ≠ 0 dB (pass-through only).
final class PassThroughBridge {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let peakingEQ = PeakingBiquad()
    private var tapInstalled = false

    private(set) var isRunning = false
    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    /// Fixed test band: 1 kHz peaking, Q ≈ 1.41.
    var testEQFrequencyHz: Double { PeakingBiquad.defaultFrequency }
    var testEQQ: Double { PeakingBiquad.defaultQ }

    var isEQBypassed: Bool { peakingEQ.isBypassed }
    var eqGainDB: Double { peakingEQ.currentGainDB }

    func setEQGainDB(_ gainDB: Double) {
        peakingEQ.setGainDB(gainDB)
    }

    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        stop()

        guard inputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingVirtualDevice }
        guard outputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingDAC }
        guard inputDeviceID != outputDeviceID else {
            throw PassThroughError.engine("Virtual input and DAC output must be different devices (feedback loop).")
        }

        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID

        if player.engine == nil {
            engine.attach(player)
        }

        try Self.setCurrentDevice(inputDeviceID, onIONode: engine.inputNode)
        try Self.setCurrentDevice(outputDeviceID, onIONode: engine.outputNode)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine("Virtual device returned an invalid input format.")
        }

        peakingEQ.configure(sampleRate: inputFormat.sampleRate)
        peakingEQ.resetState(channelCount: Int(inputFormat.channelCount))

        // Tap capture → optional EQ → player → mixer → DAC.
        // Do not connect inputNode into the mixer (would double the dry signal).
        engine.connect(player, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 1.0

        let bufferSize: AVAudioFrameCount = 512
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy before mutate — tap buffers can be reused by the engine.
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
            self.player.scheduleBuffer(copy, completionHandler: nil)
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
        player.play()
        isRunning = true
    }

    func stop() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if player.isPlaying {
            player.stop()
        }
        if engine.isRunning {
            engine.stop()
        }
        engine.disconnectNodeOutput(player)
        engine.reset()
        isRunning = false
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
    }

    func restartIfRunning(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        guard isRunning || self.inputDeviceID != kAudioObjectUnknown else { return }
        let gain = peakingEQ.currentGainDB
        try start(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
        peakingEQ.setGainDB(gain)
    }

    private static func setCurrentDevice(_ deviceID: AudioDeviceID, onIONode node: AVAudioIONode) throws {
        guard let audioUnit = node.audioUnit else {
            throw PassThroughError.engine("Missing AudioUnit for I/O node.")
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
            throw PassThroughError.audioUnit(status, "setting current device")
        }
    }
}
