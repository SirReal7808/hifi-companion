import CoreAudio
import Foundation

enum PhysicalFormatChooser {
    /// True when matching a track would leave the DAC exactly as it is and the tap is already
    /// running there at that rate (or the equalizer is off): stopping the tap, rewriting the
    /// same format and rebuilding would only add a ~0.2 s gap. Detection sources disagree on
    /// a track's bit depth (ALAC 16-bit vs AudioQueue 24-bit), and both land on the same 24-bit
    /// container — a late second detection used to rebuild the tap mid-track. Pure; unit-tested.
    static func isNoOpSwitch(
        planned: AudioFormatInfo?,
        current: AudioFormatInfo?,
        equalizerEnabled: Bool,
        tapRunningOnDevice: Bool,
        tapSampleRate: Double
    ) -> Bool {
        guard let planned, let current,
              abs(planned.sampleRate - current.sampleRate) < 1,
              planned.bitDepth == current.bitDepth
        else { return false }
        guard equalizerEnabled else { return true }
        return tapRunningOnDevice && abs(tapSampleRate - planned.sampleRate) < 1
    }

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
