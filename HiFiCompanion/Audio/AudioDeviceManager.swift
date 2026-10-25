import CoreAudio
import Foundation

enum AudioDeviceError: LocalizedError {
    case coreAudio(OSStatus, String)
    case unsupportedRate(Double)
    case noOutputStream
    case deviceMissing

    var errorDescription: String? {
        switch self {
        case .coreAudio(let status, let context):
            return "Core Audio error \(status) while \(context)"
        case .unsupportedRate(let rate):
            return "Device does not support \(AudioFormatInfo.formatRate(rate))"
        case .noOutputStream:
            return "No output stream on device"
        case .deviceMissing:
            return "Output device not found"
        }
    }
}

final class AudioDeviceManager {
    func outputDevices() -> [AudioOutputDevice] {
        deviceIDs().compactMap { id in
            guard hasOutputChannels(id) else { return nil }
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func defaultOutputDevice() -> AudioOutputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        guard let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
              let name = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
        else { return nil }
        return AudioOutputDevice(id: deviceID, uid: uid, name: name)
    }

    func currentFormat(for deviceID: AudioDeviceID) -> AudioFormatInfo? {
        let rate = nominalSampleRate(deviceID)
        let bitDepth = currentPhysicalBitDepth(deviceID) ?? 0
        guard let rate, bitDepth > 0 else {
            if let rate {
                return AudioFormatInfo(sampleRate: rate, bitDepth: bitDepth > 0 ? bitDepth : 24)
            }
            return nil
        }
        return AudioFormatInfo(sampleRate: rate, bitDepth: bitDepth)
    }

    /// Applies sample rate and, when possible, bit depth. Never forces an unsupported rate.
    /// Prefers packing 16-bit into a 24-bit container over downconverting when 16-bit is unavailable.
    @discardableResult
    func apply(format: AudioFormatInfo, to deviceID: AudioDeviceID) throws -> AudioFormatInfo {
        let supportedRates = availableNominalSampleRates(deviceID)
        guard supportedRates.contains(where: { approximatelyEqual($0, format.sampleRate) }) else {
            throw AudioDeviceError.unsupportedRate(format.sampleRate)
        }

        let physicalFormats = availablePhysicalFormats(deviceID)
        if let chosen = PhysicalFormatChooser.choose(
            requested: format,
            available: physicalFormats
        ) {
            try setPhysicalFormat(chosen, on: deviceID)
            // Nominal rate usually follows physical format; set explicitly for devices that need it.
            try setNominalSampleRate(chosen.mSampleRate, on: deviceID)
            return AudioFormatInfo(
                sampleRate: chosen.mSampleRate,
                bitDepth: Int(chosen.mBitsPerChannel)
            )
        }

        try setNominalSampleRate(format.sampleRate, on: deviceID)
        let appliedBitDepth = currentPhysicalBitDepth(deviceID) ?? format.bitDepth
        return AudioFormatInfo(sampleRate: format.sampleRate, bitDepth: appliedBitDepth)
    }

    // MARK: - Core Audio helpers

    private func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &ids
        ) == noErr else { return [] }
        return ids
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, raw) == noErr else {
            return false
        }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate) == noErr else {
            return nil
        }
        return rate
    }

    private func availableNominalSampleRates(_ deviceID: AudioDeviceID) -> [Double] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &ranges) == noErr else {
            return []
        }

        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                // Discrete endpoints plus common rates inside the range.
                for candidate in [range.mMinimum, range.mMaximum, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000] {
                    if candidate >= range.mMinimum && candidate <= range.mMaximum {
                        rates.insert(candidate)
                    }
                }
            }
        }
        return rates.sorted()
    }

    private func outputStreams(_ deviceID: AudioDeviceID) -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams) == noErr else {
            return []
        }
        return streams
    }

    private func availablePhysicalFormats(_ deviceID: AudioDeviceID) -> [AudioStreamBasicDescription] {
        guard let stream = outputStreams(deviceID).first else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.size
        var ranged = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: count
        )
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &ranged) == noErr else {
            return []
        }
        return ranged.map(\.mFormat)
    }

    private func currentPhysicalBitDepth(_ deviceID: AudioDeviceID) -> Int? {
        guard let stream = outputStreams(deviceID).first else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        return Int(asbd.mBitsPerChannel)
    }

    private func setNominalSampleRate(_ rate: Double, on deviceID: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw AudioDeviceError.coreAudio(status, "setting nominal sample rate")
        }
    }

    private func setPhysicalFormat(_ format: AudioStreamBasicDescription, on deviceID: AudioDeviceID) throws {
        guard let stream = outputStreams(deviceID).first else {
            throw AudioDeviceError.noOutputStream
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = format
        let size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectSetPropertyData(stream, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw AudioDeviceError.coreAudio(status, "setting physical format")
        }
    }

    private func approximatelyEqual(_ a: Double, _ b: Double) -> Bool {
        abs(a - b) < 1.0
    }
}
