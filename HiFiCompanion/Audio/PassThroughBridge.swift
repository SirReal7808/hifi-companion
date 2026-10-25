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
            return "Microphone access is required to capture from the virtual device."
        case .audioUnit(let status, let context):
            return "Audio unit error \(status) while \(context)"
        case .engine(let message):
            return message
        }
    }
}

/// Captures PCM from a virtual loopback device and writes it unchanged to a hardware DAC.
/// Uses AVAudioEngine with no DSP — a transparent hop, not exclusive bit-perfect I/O.
final class PassThroughBridge {
    private let engine = AVAudioEngine()
    private(set) var isRunning = false
    private(set) var inputDeviceID: AudioDeviceID = kAudioObjectUnknown
    private(set) var outputDeviceID: AudioDeviceID = kAudioObjectUnknown

    func start(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        stop()

        guard inputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingVirtualDevice }
        guard outputDeviceID != kAudioObjectUnknown else { throw PassThroughError.missingDAC }
        guard inputDeviceID != outputDeviceID else {
            throw PassThroughError.engine("Virtual input and DAC output must be different devices (feedback loop).")
        }

        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID

        // Configure devices on the underlying HAL units before connecting.
        try Self.setCurrentDevice(inputDeviceID, onIONode: engine.inputNode)
        try Self.setCurrentDevice(outputDeviceID, onIONode: engine.outputNode)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine("Virtual device returned an invalid input format.")
        }

        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: inputFormat)
        engine.mainMixerNode.outputVolume = 1.0

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()
        // Disconnect graph so the next start can rebuild cleanly.
        engine.disconnectNodeInput(engine.mainMixerNode)
        isRunning = false
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
    }

    /// Restart after SB changes so the graph picks up the new device rate.
    func restartIfRunning(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) throws {
        guard isRunning || self.inputDeviceID != kAudioObjectUnknown else { return }
        try start(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
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
