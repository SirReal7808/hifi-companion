import CoreAudio
import Foundation

struct AudibleClient: Equatable, Sendable {
    var pid: pid_t
    var bundleID: String
}

/// Lists processes with active output IO on a given Core Audio device.
final class DeviceAudioClientProbe {
    /// Bundle IDs that are Apple Music (allowed while matching).
    static let musicBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.apple.iTunes"
    ]

    /// Our own app — never counts as a competing client.
    static let selfBundleIDs: Set<String> = [
        "com.hificompanion.app"
    ]

    /// Short system UI / notification sounds that should not lock matching.
    static let ignoredSystemBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.ControlCenter",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
        "com.apple.TextInputUI",
        "com.apple.loginwindow",
        "com.apple.Dock",
        "com.apple.SystemUIServer",
        "com.apple.HiFiCompanion", // alternate product id if signed differently
        "com.apple.audio.Core-Audio-Driver-Service"
    ]

    private let selfPID = ProcessInfo.processInfo.processIdentifier

    /// Competing (non-Music) clients currently running output on `deviceID`.
    func competingOutputClients(on deviceID: AudioDeviceID) -> [AudibleClient] {
        processObjectIDs().compactMap { processID -> AudibleClient? in
            guard isRunningOutput(processID) else { return nil }
            guard usesDeviceForOutput(processID, deviceID: deviceID) else { return nil }

            let pid = pid_t(integerProperty(processID, selector: kAudioProcessPropertyPID) ?? 0)
            if pid == selfPID { return nil }

            let bundleID = stringProperty(processID, selector: kAudioProcessPropertyBundleID) ?? ""
            if Self.musicBundleIDs.contains(bundleID) { return nil }
            if Self.selfBundleIDs.contains(bundleID) { return nil }
            if Self.ignoredSystemBundleIDs.contains(bundleID) { return nil }

            // Empty bundle ID with no useful identity — treat as ignorable unless it persists;
            // still report it so grace logic can decide.
            return AudibleClient(pid: pid, bundleID: bundleID.isEmpty ? "unknown.\(pid)" : bundleID)
        }
    }

    func hasCompetingOutput(on deviceID: AudioDeviceID) -> Bool {
        !competingOutputClients(on: deviceID).isEmpty
    }

    // MARK: - Core Audio

    private func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
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

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
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

    private func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        integerProperty(processObject, selector: kAudioProcessPropertyIsRunningOutput).map { $0 != 0 } ?? false
    }

    private func usesDeviceForOutput(_ processObject: AudioObjectID, deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &size)
        if sizeStatus != noErr || size == 0 {
            // Fall back to global scope if output scope is unavailable.
            address.mScope = kAudioObjectPropertyScopeGlobal
            guard AudioObjectGetPropertyDataSize(processObject, &address, 0, nil, &size) == noErr,
                  size > 0
            else { return false }
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(processObject, &address, 0, nil, &size, &devices) == noErr else {
            return false
        }
        return devices.contains(deviceID)
    }

    private func integerProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    private func stringProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
