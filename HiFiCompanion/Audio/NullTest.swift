import CoreAudio
import Foundation

/// `--null-test`: does a flat equalizer pass audio through bit-exact? A known 24-bit signal is
/// played into the tap; what the IOProc hands the DAC is recorded and compared sample by sample.
/// Signal generation and comparison are pure; unit-tested.
enum NullTest {
    /// Peak of the test noise: 2^15 of 2^23 full scale ≈ −48 dBFS (soft, still 16 active bits).
    static let noisePeak: Int32 = 1 << 15
    static let int24FullScale: Float = 8_388_608 // 2^23

    /// Deterministic pseudo-random 24-bit stereo noise with `leadInFrames` of silence first.
    static func referenceInt24(frames: Int, channels: Int, leadInFrames: Int, seed: UInt64 = 0x5EED) -> [Int32] {
        var state = seed
        var out = [Int32](repeating: 0, count: (leadInFrames + frames) * channels)
        for i in (leadInFrames * channels)..<out.count {
            // 64-bit LCG (Knuth MMIX); top bits → −noisePeak…noisePeak−1.
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let r = Int32(truncatingIfNeeded: state >> 40) // 24 bits
            out[i] = (r % (2 * noisePeak)) - noisePeak
        }
        return out
    }

    /// Core Audio's integer → Float32 scale for 24-bit PCM (exact: 24 bits fit the mantissa).
    static func float(fromInt24 values: [Int32]) -> [Float] {
        values.map { Float($0) / int24FullScale }
    }

    struct Result: Equatable {
        var aligned: Bool
        /// Captured frame where the reference's first non-silent frame was found.
        var offsetFrames: Int
        var comparedSamples: Int
        /// Reference samples from its first non-silent frame on; all must be in the capture.
        var expectedSamples: Int
        var mismatches: Int
        var maxAbsDiff: Float
        /// 20·log10(rms(diff) / rms(reference)); −infinity when bit-exact.
        var nullDepthDB: Double

        /// Every reference sample captured (a cut-short capture never passes) and none differ.
        var isBitExact: Bool { aligned && comparedSamples > 0 && comparedSamples == expectedSamples && mismatches == 0 }
    }

    /// Find the reference in the capture and compare the overlap. Exact alignment first (a frame
    /// that matches bit for bit and the next 31 frames too); if none, the best cross-correlation
    /// lag over the first `probeFrames` of signal, so a resampled path still gets a null depth.
    static func compare(reference: [Float], captured: [Float], channels: Int, probeFrames: Int = 2_048) -> Result {
        let ch = max(channels, 1)
        let refFrames = reference.count / ch
        let capFrames = captured.count / ch
        let none = Result(aligned: false, offsetFrames: -1, comparedSamples: 0, expectedSamples: 0, mismatches: 0, maxAbsDiff: 0, nullDepthDB: 0)
        guard let first = (0..<refFrames).first(where: { f in (0..<ch).contains { reference[f * ch + $0] != 0 } }),
              capFrames > 0
        else { return none }

        func framesMatch(capture c: Int, reference r: Int, count: Int) -> Bool {
            guard c + count <= capFrames, r + count <= refFrames else { return false }
            for k in 0..<(count * ch) where captured[c * ch + k] != reference[r * ch + k] { return false }
            return true
        }

        var lag: Int?
        let run = min(32, refFrames - first)
        for c in 0..<capFrames where framesMatch(capture: c, reference: first, count: run) {
            lag = c - first
            break
        }
        if lag == nil {
            lag = bestCorrelationLag(reference: reference, captured: captured, channels: ch, from: first, probeFrames: probeFrames)
        }
        guard let lag else { return none }

        var compared = 0, mismatches = 0
        var maxDiff: Float = 0
        var diffEnergy = 0.0, refEnergy = 0.0
        for f in first..<refFrames {
            let c = f + lag
            guard c >= 0, c < capFrames else { continue }
            for k in 0..<ch {
                let r = reference[f * ch + k]
                let d = captured[c * ch + k] - r
                compared += 1
                if d != 0 { mismatches += 1 }
                maxDiff = max(maxDiff, abs(d))
                diffEnergy += Double(d) * Double(d)
                refEnergy += Double(r) * Double(r)
            }
        }
        let depth = diffEnergy == 0 ? -Double.infinity : 10 * log10(diffEnergy / max(refEnergy, .leastNonzeroMagnitude))
        return Result(
            aligned: compared > 0,
            offsetFrames: first + lag,
            comparedSamples: compared,
            expectedSamples: (refFrames - first) * ch,
            mismatches: mismatches,
            maxAbsDiff: maxDiff,
            nullDepthDB: depth
        )
    }

    /// Lag (capture frame − reference frame) with the largest correlation of channel 0.
    private static func bestCorrelationLag(
        reference: [Float],
        captured: [Float],
        channels ch: Int,
        from first: Int,
        probeFrames: Int
    ) -> Int? {
        let refFrames = reference.count / ch
        let capFrames = captured.count / ch
        let probe = min(probeFrames, refFrames - first)
        guard probe > 16, capFrames >= probe else { return nil }
        var best = -Double.infinity
        var bestLag: Int?
        for c in 0...(capFrames - probe) {
            var sum = 0.0
            for i in 0..<probe {
                sum += Double(reference[(first + i) * ch]) * Double(captured[(c + i) * ch])
            }
            if sum > best {
                best = sum
                bestLag = c - first
            }
        }
        return best > 0 ? bestLag : nil
    }

    static func summary(_ r: Result, label: String, sampleRate: Double, channels: Int) -> String {
        let verdict: String
        if !r.aligned {
            verdict = "NOT FOUND (test signal not in the capture — was something else playing, or the tap silent?)"
        } else if r.isBitExact {
            verdict = "BIT-EXACT"
        } else if r.mismatches == 0 {
            verdict = "INCOMPLETE (capture cut short: \(r.comparedSamples) of \(r.expectedSamples) samples)"
        } else {
            verdict = String(format: "NOT bit-exact (null depth %.1f dB)", r.nullDepthDB)
        }
        return "NULL_TEST: [\(label)] tap=\(Int(sampleRate)) Hz ch=\(channels) "
            + "compared=\(r.comparedSamples) mismatches=\(r.mismatches) maxDiff=\(r.maxAbsDiff) → \(verdict)"
    }
}

/// Copies what the IOProc hands the DAC into a preallocated buffer (`--null-test` only).
/// Realtime-safe: no allocation, no lock in `append`. `prepare` runs in `start` before IO begins;
/// only the IO thread writes after that; read `samples()` after the bridge stops.
final class NullTestRecorder: @unchecked Sendable {
    private let frames: Int
    private(set) var channels = 0
    /// The tap's actual rate (not the file's), for the report.
    private(set) var sampleRate: Double = 0
    private var capacity = 0
    private var buffer: UnsafeMutablePointer<Float>?
    private var written = 0

    init(frames: Int) {
        self.frames = max(frames, 1)
    }

    deinit { buffer?.deallocate() }

    /// Allocate for the tap's channel count (called by the bridge before IO starts).
    func prepare(channels: Int, sampleRate: Double) {
        buffer?.deallocate()
        self.channels = max(channels, 1)
        self.sampleRate = sampleRate
        capacity = frames * self.channels
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        buffer = storage
        written = 0
    }

    /// Interleaved copy of `frames` from an interleaved or planar buffer list.
    func append(_ abl: UnsafeMutableAudioBufferListPointer, frames: Int, interleaved: Bool) {
        guard let buffer, channels > 0 else { return }
        var n = min(frames, (capacity - written) / channels)
        guard n > 0, let first = abl.first else { return }
        let floatsInFirst = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        if interleaved {
            // Never read past the output buffer, whatever `frames` the input implied.
            n = min(n, floatsInFirst / channels)
            guard n > 0, let src = first.mData?.assumingMemoryBound(to: Float.self) else { return }
            (buffer + written).update(from: src, count: n * channels)
        } else {
            n = min(n, floatsInFirst)
            guard n > 0 else { return }
            for c in 0..<min(channels, abl.count) {
                guard let src = abl[c].mData?.assumingMemoryBound(to: Float.self),
                      Int(abl[c].mDataByteSize) / MemoryLayout<Float>.size >= n
                else { continue }
                for i in 0..<n { buffer[written + i * channels + c] = src[i] }
            }
        }
        written += n * channels
    }

    /// Recorded samples, interleaved, first `keepChannels` channels. Call after the bridge stops.
    func samples(keepChannels: Int) -> [Float] {
        guard let buffer, channels > 0 else { return [] }
        let keep = min(max(keepChannels, 1), channels)
        let recorded = written / channels
        var out = [Float]()
        out.reserveCapacity(recorded * keep)
        for f in 0..<recorded {
            for c in 0..<keep { out.append(buffer[f * channels + c]) }
        }
        return out
    }
}
