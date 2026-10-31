import Foundation

/// Optional menu bar title items (docs/redesign-0.3.md → Menu bar). Pure; unit-tested.
enum MenuBarTitleItem: String, CaseIterable, Identifiable, Codable, Sendable {
    case device
    case sampleFormat
    case profile

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .device: return "Device"
        case .sampleFormat: return "SB (sample rate / bit depth)"
        case .profile: return "Profile"
        }
    }
}

enum MenuBarTitle {
    /// Placeholder until the logo exists.
    static let placeholder = "HiFi Companion"
    static let separator = " · "
    /// Longest single item before it is truncated with an ellipsis.
    static let maxItemLength = 18

    /// The selected items that have a value, in fixed order (Device · SB · Profile), each
    /// truncated. The items replace the placeholder text (the logo, once it exists, sits in
    /// front of them); with nothing selected or nothing to show, only the placeholder.
    static func compose(
        items: Set<MenuBarTitleItem>,
        device: String?,
        sampleFormat: String?,
        profile: String?
    ) -> String {
        let values: [String?] = MenuBarTitleItem.allCases.map { item in
            guard items.contains(item) else { return nil }
            switch item {
            case .device: return device
            case .sampleFormat: return sampleFormat
            case .profile: return profile
            }
        }
        let parts = values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(truncate)
        return parts.isEmpty ? placeholder : parts.joined(separator: separator)
    }

    static func truncate(_ text: String) -> String {
        guard text.count > maxItemLength else { return text }
        return text.prefix(maxItemLength - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Compact SB for the title, e.g. `44.1/24`.
    static func compactFormat(_ format: AudioFormatInfo) -> String {
        let rate = AudioFormatInfo.formatRate(format.sampleRate).replacingOccurrences(of: " kHz", with: "")
        return "\(rate)/\(format.bitDepth)"
    }
}
