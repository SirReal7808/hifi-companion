import Foundation

/// Known virtual loopback devices used as the pass-through hop source.
///
/// v1 vendors [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) (MIT) rather than
/// shipping a first-party Audio Server Plug-in. A custom ASP remains the longer-term path.
enum VirtualDeviceCatalog {
    static let blackHole2chUID = "BlackHole2ch_UID"
    static let preferredNameHints = ["BlackHole 2ch", "BlackHole"]

    static func isVirtualLoopback(uid: String, name: String) -> Bool {
        if uid == blackHole2chUID { return true }
        let lowered = name.lowercased()
        if lowered.contains("blackhole") || lowered.contains("black hole") {
            return true
        }
        // Multi-Output / Aggregate devices built only to host BlackHole for bridging.
        let isAggregateFamily =
            lowered.contains("multi-output")
            || lowered.contains("multi output")
            || lowered.contains("aggregate")
        if isAggregateFamily && (lowered.contains("blackhole") || lowered.contains("black hole") || lowered.contains("hifi")) {
            return true
        }
        return false
    }

    static func isPreferredVirtual(uid: String, name: String) -> Bool {
        if uid == blackHole2chUID { return true }
        return name.localizedCaseInsensitiveContains("BlackHole 2ch")
    }
}
