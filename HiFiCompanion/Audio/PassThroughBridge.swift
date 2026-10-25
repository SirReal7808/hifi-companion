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
            return "Input access denied. System Settings → Privacy & Security → Microphone → enable HiFi Companion, then try Pass-through again. Without this, BlackHole cannot be captured."
        case .audioUnit(let status, let context):
            return "Audio unit error \(status) while \(context)"
        case .engine(let message):
            return message
        }
    }
}

/// Captures PCM from a virtual loopback device and plays it on a hardware DAC.
/// Graph: BlackHole input → peaking EQ → mixer → pinned DAC (no tap→player hop).
final class PassThroughBridge: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "PassThroughBridge")
    private let queue = DispatchQueue(label: "com.hificompanion.passthrough")
    private let peakingEQ = PeakingBiquad()

    private var engine: AVAudioEngine?
    private var eqUnit: AVAudioUnitEQ?
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
        queue.async { [weak self] in
            self?.applyEQGainToUnit()
        }
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
            applyEQGainToUnit()
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

        let newEngine = AVAudioEngine()
        let newEQ = AVAudioUnitEQ(numberOfBands: 1)
        configureEQUnit(newEQ)

        newEngine.attach(newEQ)

        // Bind HAL devices before reading formats / connecting.
        try Self.setCurrentDevice(inputDeviceID, onIONode: newEngine.inputNode)
        try Self.setCurrentDevice(outputDeviceID, onIONode: newEngine.outputNode)

        let inputFormat = newEngine.inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw PassThroughError.engine(
                "Virtual device returned an invalid input format (rate \(inputFormat.sampleRate), ch \(inputFormat.channelCount)). Check Input permission and BlackHole."
            )
        }

        peakingEQ.configure(sampleRate: inputFormat.sampleRate)
        peakingEQ.resetState(channelCount: Int(inputFormat.channelCount))

        // Direct hardware pull: input → EQ → mixer → DAC.
        // Avoid tap→player; that path failed silently and raced teardown on toggle.
        newEngine.connect(newEngine.inputNode, to: newEQ, format: inputFormat)
        newEngine.connect(newEQ, to: newEngine.mainMixerNode, format: inputFormat)
        newEngine.mainMixerNode.outputVolume = 1.0

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            newEngine.stop()
            throw PassThroughError.engine("Bridge engine failed to start: \(error.localizedDescription)")
        }

        self.engine = newEngine
        self.eqUnit = newEQ
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.runningFlag = true
        applyEQGainToUnit()
        log.info("Pass-through bridge running (in=\(inputDeviceID, privacy: .public) out=\(outputDeviceID, privacy: .public) \(inputFormat.sampleRate, privacy: .public)Hz)")
    }

    private func stopLocked() {
        let wasRunning = runningFlag
        runningFlag = false

        if let engine {
            if engine.isRunning {
                engine.stop()
            }
            if let eqUnit {
                engine.disconnectNodeInput(eqUnit)
                engine.disconnectNodeOutput(eqUnit)
                engine.detach(eqUnit)
            }
            // Do not call engine.reset() — it races menu teardown and caused SIGBUS crashes.
        }

        engine = nil
        eqUnit = nil
        inputDeviceID = kAudioObjectUnknown
        outputDeviceID = kAudioObjectUnknown
        if wasRunning {
            log.info("Pass-through bridge stopped")
        }
    }

    private func configureEQUnit(_ unit: AVAudioUnitEQ) {
        unit.bypass = false
        let band = unit.bands[0]
        band.filterType = .parametric
        band.frequency = Float(PeakingBiquad.defaultFrequency)
        // Octaves ≈ 2·asinh(1/(2Q))/ln(2); Q≈1.41 → ~1.0 octave.
        let q = PeakingBiquad.defaultQ
        let halfInvQ = 1.0 / (2.0 * q)
        let bandwidthOctaves = 2.0 * Darwin.asinh(halfInvQ) / Darwin.log(2.0)
        band.bandwidth = Float(bandwidthOctaves)
        band.gain = 0
        band.bypass = true
    }

    private func applyEQGainToUnit() {
        guard let unit = eqUnit else { return }
        let gain = peakingEQ.currentGainDB
        let band = unit.bands[0]
        band.gain = Float(gain)
        band.bypass = abs(gain) < PeakingBiquad.bypassThresholdDB
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
            throw PassThroughError.audioUnit(status, "setting current device \(deviceID)")
        }
    }
}
