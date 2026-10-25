import Foundation

/// Pure logic for 10-band peaking cascade headroom (testable without Core Audio).
enum PEQHeadroom {
    /// Soft headroom so outputGainDB + peakBoostDB stays under 0 dB by this margin.
    static let headroomDB: Double = 0.5

    /// Log-spaced magnitude samples of the enabled peaking cascade; returns max gain in dB (≥ 0).
    static func peakBoostDB(
        bands: [EQBand],
        sampleRate: Double,
        sampleCount: Int = 256
    ) -> Double {
        let nyquist = max(sampleRate * 0.5 - 1, 40)
        let lo = 20.0
        let hi = min(20_000.0, nyquist)
        guard hi > lo, sampleCount > 1 else { return 0 }

        let active = bands.filter { !$0.isAudiblyFlat && $0.filterType == .peaking }
        guard !active.isEmpty else { return 0 }

        var peak = -Double.greatestFiniteMagnitude
        let logLo = log(lo)
        let logHi = log(hi)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let hz = exp(logLo + t * (logHi - logLo))
            var sum = 0.0
            for band in active {
                sum += peakingMagnitudeDB(
                    centerHz: band.frequencyHz,
                    gainDB: band.gainDB,
                    q: band.q,
                    atHz: hz,
                    sampleRate: sampleRate
                )
            }
            peak = max(peak, sum)
        }
        return max(0, peak)
    }

    /// Highest output gain that keeps `output + peakBoost <= -headroom`.
    static func safeCeilingOutputGainDB(peakBoostDB: Double) -> Double {
        -peakBoostDB - headroomDB
    }

    /// True when the user-held output gain exceeds the safe ceiling.
    static func isAboveSafeCeiling(outputGainDB: Double, peakBoostDB: Double) -> Bool {
        outputGainDB > safeCeilingOutputGainDB(peakBoostDB: peakBoostDB) + 1e-9
    }

    /// After a band edit: auto-lower output gain to the ceiling if needed; never auto-raise.
    static func applyBandChange(
        bands: [EQBand],
        outputGainDB: Double,
        sampleRate: Double
    ) -> (outputGainDB: Double, peakBoostDB: Double, clippingWarning: Bool) {
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate)
        let ceiling = safeCeilingOutputGainDB(peakBoostDB: boost)
        let lowered = min(outputGainDB, ceiling)
        let warning = isAboveSafeCeiling(outputGainDB: lowered, peakBoostDB: boost)
        return (lowered, boost, warning)
    }

    /// Manual output-gain edit: keep the user’s value; set warning if above ceiling.
    static func applyManualOutputGain(
        requested: Double,
        bands: [EQBand],
        sampleRate: Double
    ) -> (outputGainDB: Double, peakBoostDB: Double, clippingWarning: Bool) {
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate)
        let warning = isAboveSafeCeiling(outputGainDB: requested, peakBoostDB: boost)
        return (requested, boost, warning)
    }

    /// Analytical peaking magnitude (RBJ) at one frequency.
    static func peakingMagnitudeDB(
        centerHz: Double,
        gainDB: Double,
        q: Double,
        atHz: Double,
        sampleRate: Double
    ) -> Double {
        let sr = max(sampleRate, 1)
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * centerHz / sr
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * max(q, 0.1))

        let b0 = (1.0 + alpha * A) / (1.0 + alpha / A)
        let b1 = (-2.0 * cosw0) / (1.0 + alpha / A)
        let b2 = (1.0 - alpha * A) / (1.0 + alpha / A)
        let a1 = (-2.0 * cosw0) / (1.0 + alpha / A)
        let a2 = (1.0 - alpha / A) / (1.0 + alpha / A)

        let w = 2.0 * Double.pi * atHz / sr
        let z1r = cos(w), z1i = -sin(w)
        let z2r = cos(2 * w), z2i = -sin(2 * w)
        let numR = b0 + b1 * z1r + b2 * z2r
        let numI = b1 * z1i + b2 * z2i
        let denR = 1.0 + a1 * z1r + a2 * z2r
        let denI = a1 * z1i + a2 * z2i
        let denMag2 = denR * denR + denI * denI
        guard denMag2 > 0 else { return 0 }
        let mag2 = (numR * numR + numI * numI) / denMag2
        return 10.0 * log10(max(mag2, 1e-30))
    }
}

/// Realtime 10-band peaking cascade + output gain for the process-tap path.
final class PEQProcessor: @unchecked Sendable {
    static let bandCount = 10

    private let lock = NSLock()
    private var bands: [EQBand] = EQBand.defaultTenBands()
    private var sections: [PeakingBiquad] = (0..<bandCount).map { _ in PeakingBiquad() }
    private var sampleRate: Double = 48_000
    private var outputGainDB: Double = 0
    private var outputLinear: Float = 1
    private var bypassBands = false
    private var channelCount = 2

    var currentBands: [EQBand] {
        lock.lock(); defer { lock.unlock() }
        return bands
    }

    var currentOutputGainDB: Double {
        lock.lock(); defer { lock.unlock() }
        return outputGainDB
    }

    var isBypassed: Bool {
        lock.lock(); defer { lock.unlock() }
        return bypassBands
    }

    /// True when any enabled band has non-zero gain and bands are not bypassed.
    var isColoring: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !bypassBands else { return false }
        return bands.contains { !$0.isAudiblyFlat }
    }

    func configure(sampleRate: Double, channelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = max(channelCount, 1)
        rebuildSectionsLocked()
    }

    func setState(bands: [EQBand], outputGainDB: Double, bypass: Bool) {
        lock.lock()
        defer { lock.unlock() }
        precondition(bands.count == Self.bandCount)
        self.bands = bands
        self.outputGainDB = outputGainDB
        self.outputLinear = Float(pow(10.0, outputGainDB / 20.0))
        self.bypassBands = bypass
        rebuildSectionsLocked()
    }

    func setOutputGainDB(_ gainDB: Double) {
        lock.lock()
        defer { lock.unlock() }
        outputGainDB = gainDB
        outputLinear = Float(pow(10.0, gainDB / 20.0))
    }

    func setBypass(_ bypass: Bool) {
        lock.lock()
        defer { lock.unlock() }
        bypassBands = bypass
    }

    func resetState(channelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.channelCount = max(channelCount, 1)
        for section in sections {
            section.resetState(channelCount: self.channelCount)
        }
    }

    func peakBoostDB() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sampleRate)
    }

    /// Cascade bands (unless bypassed), then always apply output gain.
    func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        let bypass = bypassBands
        let gain = outputLinear
        let activeSections = bypass ? [] : sections
        let bandSnapshot = bypass ? [] : bands
        lock.unlock()

        if !bypass {
            for (index, section) in activeSections.enumerated() {
                guard index < bandSnapshot.count, !bandSnapshot[index].isAudiblyFlat else { continue }
                section.processInterleaved(samples, frames: frames, channels: channels)
            }
        }

        if abs(gain - 1) < 1e-6 { return }
        let n = frames * channels
        for i in 0..<n {
            samples[i] *= gain
        }
    }

    func processChannel(_ samples: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        lock.lock()
        let bypass = bypassBands
        let gain = outputLinear
        let activeSections = bypass ? [] : sections
        let bandSnapshot = bypass ? [] : bands
        lock.unlock()

        if !bypass {
            for (index, section) in activeSections.enumerated() {
                guard index < bandSnapshot.count, !bandSnapshot[index].isAudiblyFlat else { continue }
                section.processChannel(samples, frames: frames, channel: channel)
            }
        }

        if abs(gain - 1) < 1e-6 { return }
        for i in 0..<frames {
            samples[i] *= gain
        }
    }

    private func rebuildSectionsLocked() {
        while sections.count < Self.bandCount {
            sections.append(PeakingBiquad())
        }
        for i in 0..<Self.bandCount {
            let band = bands[i]
            let section = sections[i]
            section.configure(
                sampleRate: sampleRate,
                frequency: band.frequencyHz,
                q: band.q
            )
            section.setGainDB(band.isAudiblyFlat ? 0 : band.gainDB)
            section.resetState(channelCount: channelCount)
        }
    }
}
