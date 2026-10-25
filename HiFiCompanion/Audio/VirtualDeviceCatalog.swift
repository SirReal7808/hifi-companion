import Foundation

/// Outputs that must not be pinned as the hardware DAC (virtual loopbacks, bridge aggregates).
/// Pass-through does **not** use these devices — it uses a Core Audio process tap on the real DAC.
enum VirtualDeviceCatalog {
    static func isVirtualLoopback(uid: String, name: String) -> Bool {
        let lowered = name.lowercased()
        let uidLower = uid.lowercased()

        // Common third-party / system virtual outputs (exclusion only — not a PT hop).
        let virtualNameHints = [
            "blackhole", "black hole", "soundflower", "loopback", "virtual",
            "cable", "vb-audio", "voiceimeter", "waveterminal"
        ]
        if virtualNameHints.contains(where: { lowered.contains($0) || uidLower.contains($0) }) {
            return true
        }

        let isAggregateFamily =
            lowered.contains("multi-output")
            || lowered.contains("multi output")
            || lowered.contains("aggregate")
        // Private aggregates we create for the process tap must not appear as a pin target.
        if isAggregateFamily && (lowered.contains("hificompanion") || uidLower.contains("hificompanion")) {
            return true
        }
        return false
    }
}
