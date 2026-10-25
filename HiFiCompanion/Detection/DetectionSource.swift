import Foundation

/// Where a Music format line came from. Higher raw values are trusted more.
/// Mirrors LosslessSwitcher / FantasticSkyBaby priorities: ALAC input beats AudioQueue and audioCapabilities.
enum DetectionSource: Int, Comparable, Sendable {
    case appleScript = 0
    case audioCapabilities = 1
    case audioQueue = 2
    case alacInput = 5

    static func < (lhs: DetectionSource, rhs: DetectionSource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .appleScript: return "AppleScript"
        case .audioCapabilities: return "audioCapabilities"
        case .audioQueue: return "AudioQueue"
        case .alacInput: return "ALAC"
        }
    }
}

struct FormatDetection: Equatable, Sendable {
    var format: AudioFormatInfo
    var source: DetectionSource
    var detectedAt: Date
}
