import CoreAudio
import Darwin
import Foundation

/// Tells whether one app is actually producing sound, without muting it (docs/redesign-0.3.md
/// → R4b). Browsers keep their output stream open ~10 s after a pause, so "running output"
/// alone over-reports competitors and the exclusive-Music lock lifts late.
///
/// A private, **unmuted** process tap on that app, read through a **tap-only** private
/// aggregate — no output sub-device, so it is never a second client on the DAC (a second
/// client there silenced Pass-through Music before; see pitfalls). Creating a tap needs
/// System Audio Recording, so the owner only uses this while the equalizer runs.
@available(macOS 14.2, *)
final class AudibilityProbe {
    /// ≈ −80 dBFS: below this a buffer counts as silence.
    static let threshold: Float = 1e-4
    /// Audible if a non-silent buffer arrived within this window.
    static let holdSeconds: Double = 0.5

    let pid: pid_t
    let createdAt = Date()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Written only by the IOProc, read on main: [0] host time of the last non-silent buffer,
    /// [1] callback count. Aligned 64-bit words — single loads / stores, no lock or allocation
    /// on the realtime thread; a torn read is impossible on arm64 / x86-64.
    private let words = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
    private static let ticksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()

    /// nil when the tap or aggregate cannot be created (no permission, process gone).
    init?(pid: pid_t) {
        self.pid = pid
        words.initialize(repeating: 0, count: 2)
        guard let process = Self.processObject(for: pid) else { return nil }

        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "HiFi Companion Audibility"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown,
              let tapUID = Self.stringProperty(tap, kAudioTapPropertyUID)
        else { return nil }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "HiFiCompanionAudibility",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID]]
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              device != kAudioObjectUnknown
        else {
            teardown()
            return nil
        }
        aggregateID = device

        let words = self.words
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            // Realtime: scan for any sample above threshold; no allocation, no locks.
            words[1] &+= 1
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<count where abs(data[i]) > AudibilityProbe.threshold {
                    words[0] = mach_absolute_time()
                    return
                }
            }
        }
        guard status == noErr, let proc else {
            teardown()
            return nil
        }
        procID = proc
        guard AudioDeviceStart(device, proc) == noErr else {
            teardown()
            return nil
        }
    }

    deinit {
        teardown()
        words.deallocate()
    }

    /// nil until the first buffer arrives (treat as "still playing" meanwhile).
    var isAudible: Bool? {
        guard words[1] > 0 else { return nil }
        let last = words[0]
        guard last > 0 else { return false }
        let age = Double(mach_absolute_time() &- last) / Self.ticksPerSecond
        return age < Self.holdSeconds
    }

    var callbackCount: UInt64 { words[1] }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
