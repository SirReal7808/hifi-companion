import CoreAudio
import Foundation

/// Read-only facts about the output device for Settings → Diagnostics. Pure; unit-tested.
struct OutputDeviceDetails: Equatable {
    var transportType: UInt32 = 0
    var supportedSampleRates: [Double] = []
    var supportedBitDepths: [Int] = []
    var bufferFrames: UInt32?
    /// Device + stream latency and safety offset, output scope (excludes the buffer).
    var latencyFrames: Int?
    var sampleRate: Double?

    var transportLabel: String {
        switch transportType {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeFireWire: return "FireWire"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        case kAudioDeviceTransportTypePCI: return "PCI"
        case 0: return "Unknown"
        default: return "Other"
        }
    }

    /// e.g. `44.1, 48, 88.2, 96, 176.4, 192 kHz`.
    var sampleRatesLabel: String {
        guard !supportedSampleRates.isEmpty else { return "—" }
        let values = supportedSampleRates.sorted().map { hz in
            AudioFormatInfo.formatRate(hz).replacingOccurrences(of: " kHz", with: "")
        }
        return values.joined(separator: ", ") + " kHz"
    }

    /// e.g. `16, 24, 32-bit`.
    var bitDepthsLabel: String {
        guard !supportedBitDepths.isEmpty else { return "—" }
        return supportedBitDepths.sorted().map(String.init).joined(separator: ", ") + "-bit"
    }

    /// e.g. `512 frames · 11.6 ms`.
    var bufferLabel: String {
        guard let bufferFrames else { return "—" }
        return "\(bufferFrames) frames" + Self.millisecondsSuffix(frames: Int(bufferFrames), sampleRate: sampleRate)
    }

    /// Buffer plus device latency: roughly how late the output is.
    var outputLatencyLabel: String {
        guard let bufferFrames, let latencyFrames else { return "—" }
        let total = Int(bufferFrames) + latencyFrames
        return "\(total) frames" + Self.millisecondsSuffix(frames: total, sampleRate: sampleRate)
    }

    private static func millisecondsSuffix(frames: Int, sampleRate: Double?) -> String {
        guard let sampleRate, sampleRate > 0 else { return "" }
        return String(format: " · %.1f ms", Double(frames) / sampleRate * 1000)
    }
}

/// Tap level for the Diagnostics meter. Pure; unit-tested.
enum SignalLevel {
    /// Bottom of the meter scale.
    static let floorDB: Double = -60

    /// Linear RMS → dBFS, clamped to the meter floor; nil for silence.
    static func dbfs(rms: Float) -> Double? {
        guard rms > 0 else { return nil }
        let db = 20 * log10(Double(rms))
        return db < floorDB ? nil : min(db, 0)
    }

    /// 0…1 meter fill for a dBFS value.
    static func fraction(dbfs: Double?) -> Double {
        guard let dbfs else { return 0 }
        return max(0, min(1, (dbfs - floorDB) / -floorDB))
    }
}
