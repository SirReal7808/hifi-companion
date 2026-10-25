import CoreAudio
import Foundation

enum PhysicalFormatChooser {
    /// Prefers an exact bit-depth match at the requested rate.
    /// For 16-bit sources when 16-bit is unavailable, prefers packing into a 24-bit (or wider) container
    /// instead of downconverting.
    static func choose(
        requested: AudioFormatInfo,
        available: [AudioStreamBasicDescription]
    ) -> AudioStreamBasicDescription? {
        let atRate = available.filter { abs($0.mSampleRate - requested.sampleRate) < 1.0 }
        guard !atRate.isEmpty else { return nil }

        if let exact = atRate.first(where: { Int($0.mBitsPerChannel) == requested.bitDepth }) {
            return exact
        }

        if requested.bitDepth <= 16 {
            let wider = atRate
                .filter { $0.mBitsPerChannel >= 24 }
                .sorted { $0.mBitsPerChannel < $1.mBitsPerChannel }
            if let pad = wider.first {
                return pad
            }
        }

        let notLower = atRate
            .filter { Int($0.mBitsPerChannel) >= requested.bitDepth }
            .sorted { $0.mBitsPerChannel < $1.mBitsPerChannel }
        if let up = notLower.first {
            return up
        }

        return atRate.max(by: { $0.mBitsPerChannel < $1.mBitsPerChannel })
    }
}
