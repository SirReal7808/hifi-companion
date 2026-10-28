import Foundation

/// Output rules (docs/redesign-0.3.md → Output). Pure, so it is unit-tested.
///
/// HiFi Companion always works on the macOS output. A user-picked **preferred** device is
/// made the macOS output only at three moments — when the user picks it, when it appears
/// (plugged in), and at launch — so a later manual switch in the macOS Sound menu is respected
/// instead of fought.
enum OutputPolicy {
    enum Moment {
        case launch
        /// The user picked a device in HiFi Companion.
        case userSelected
        /// Devices were added (`added` = their UIDs).
        case devicesAdded(Set<String>)
    }

    /// UID to make the macOS output now, or nil to leave the macOS output alone.
    static func systemOutputToSelect(
        at moment: Moment,
        preferredUID: String?,
        availableUIDs: Set<String>,
        systemOutputUID: String?
    ) -> String? {
        guard let preferredUID, availableUIDs.contains(preferredUID),
              systemOutputUID != preferredUID
        else { return nil }
        switch moment {
        case .launch, .userSelected:
            return preferredUID
        case .devicesAdded(let added):
            return added.contains(preferredUID) ? preferredUID : nil
        }
    }

    /// The device the equalizer and Apple Music mode act on: the macOS output, unless it is a
    /// virtual / loopback device (never processed or reclocked).
    static func target(systemOutput: AudioOutputDevice?) -> AudioOutputDevice? {
        guard let systemOutput,
              !VirtualDeviceCatalog.isVirtualLoopback(uid: systemOutput.uid, name: systemOutput.name)
        else { return nil }
        return systemOutput
    }
}
