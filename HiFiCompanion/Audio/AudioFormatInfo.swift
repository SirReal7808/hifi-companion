import Foundation

struct AudioFormatInfo: Equatable, Sendable {
    var sampleRate: Double
    var bitDepth: Int

    var shortDescription: String {
        let rate = Self.formatRate(sampleRate)
        return "\(rate) / \(bitDepth)-bit"
    }

    var menuDescription: String {
        "\(Self.formatRate(sampleRate)), \(bitDepth)-bit"
    }

    static func formatRate(_ hz: Double) -> String {
        let khz = hz / 1000.0
        if abs(khz.rounded() - khz) < 0.01 {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }
}
