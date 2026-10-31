import AppKit

/// Apps the user wants left out of the equalizer (Settings → Apps). Persisted list only:
/// the process tap does not read it yet (see docs/redesign-0.3.md → Settings window).
struct ExcludedApp: Identifiable, Equatable {
    let bundleID: String
    var id: String { bundleID }

    var displayName: String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum EqualizerExclusions {
    static let defaultsKey = "equalizerExcludedBundleIDs"

    /// Trimmed, non-empty, first occurrence kept, order preserved.
    static func normalized(_ bundleIDs: [String]) -> [String] {
        var seen = Set<String>()
        return bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
