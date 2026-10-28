import Foundation

/// Pure logic for 10-band peaking cascade headroom (testable without Core Audio).
enum PEQHeadroom {
    /// Soft margin used only when auto/“Set safe” picks an output gain under a real boost.
    static let headroomDB: Double = 0.5

    /// Practical output-gain clamp (stacking can push well below −14).
    static let minOutputGainDB: Double = -48
    static let maxOutputGainDB: Double = 12

    /// Log-spaced magnitude samples of the enabled cascade (PK / LS / HS); returns max gain in dB (≥ 0).
    static func peakBoostDB(
        bands: [EQBand],
        sampleRate: Double,
        sampleCount: Int = 256
    ) -> Double {
        let nyquist = max(sampleRate * 0.5 - 1, 40)
        let lo = 20.0
        let hi = min(20_000.0, nyquist)
        guard hi > lo, sampleCount > 1 else { return 0 }

        let active = bands.filter { !$0.isAudiblyFlat }
        guard !active.isEmpty else { return 0 }

        var peak = -Double.greatestFiniteMagnitude
        let logLo = log(lo)
        let logHi = log(hi)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let hz = exp(logLo + t * (logHi - logLo))
            peak = max(peak, cascadeMagnitudeDB(bands: active, atHz: hz, sampleRate: sampleRate))
        }
        return max(0, peak)
    }

    /// Sum of band magnitudes at one frequency (for the response graph).
    static func cascadeMagnitudeDB(bands: [EQBand], atHz: Double, sampleRate: Double) -> Double {
        var sum = 0.0
        for band in bands where !band.isAudiblyFlat {
            sum += bandMagnitudeDB(band: band, atHz: atHz, sampleRate: sampleRate)
        }
        return sum
    }

    static func bandMagnitudeDB(band: EQBand, atHz: Double, sampleRate: Double) -> Double {
        PeakingBiquad.magnitudeDB(
            filterType: band.filterType,
            centerHz: band.frequencyHz,
            gainDB: band.gainDB,
            q: band.q,
            atHz: atHz,
            sampleRate: sampleRate
        )
    }

    /// Log-spaced samples of the cascade for plotting (includes flat → zeros).
    static func responseCurveDB(
        bands: [EQBand],
        sampleRate: Double,
        sampleCount: Int = 128
    ) -> [(hz: Double, db: Double)] {
        let nyquist = max(sampleRate * 0.5 - 1, 40)
        let lo = EQBand.minFrequencyHz
        let hi = min(EQBand.maxFrequencyHz, nyquist)
        guard hi > lo, sampleCount > 1 else { return [] }
        let logLo = log(lo)
        let logHi = log(hi)
        var points: [(hz: Double, db: Double)] = []
        points.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleCount - 1)
            let hz = exp(logLo + t * (logHi - logLo))
            points.append((hz, cascadeMagnitudeDB(bands: bands, atHz: hz, sampleRate: sampleRate)))
        }
        return points
    }

    /// Auto / “Set safe” ceiling. Flat curve → 0 (0 dB out is fine). With boost → −peak − margin.
    static func safeCeilingOutputGainDB(peakBoostDB: Double) -> Double {
        let boost = max(0, peakBoostDB)
        if boost < 1e-9 { return 0 }
        return -boost - headroomDB
    }

    /// Real clipping risk only: `output + peakBoost > 0`. Flat + 0 dB out is never a warning.
    static func isClippingRisk(outputGainDB: Double, peakBoostDB: Double) -> Bool {
        outputGainDB + max(0, peakBoostDB) > 1e-9
    }

    /// Duration for Auto raises toward the safe ceiling (smooth, not a jump).
    static let autoRaiseDurationSeconds: Double = 2.0

    /// How Auto should move output gain relative to the safe ceiling.
    enum AutoGainAdjustment: Equatable {
        case leave
        /// Would clip — apply this gain immediately.
        case lowerImmediate(Double)
        /// Below ceiling — ramp toward this end value over `autoRaiseDurationSeconds`.
        case raiseRamp(Double)
    }

    /// Plan Auto movement. Clip-down is immediate; raises are ramped by the caller.
    static func autoGainAdjustment(
        currentOutputGainDB: Double,
        peakBoostDB: Double
    ) -> AutoGainAdjustment {
        let ceiling = safeCeilingOutputGainDB(peakBoostDB: peakBoostDB)
        if currentOutputGainDB > ceiling + 1e-9 {
            return .lowerImmediate(ceiling)
        }
        if currentOutputGainDB < ceiling - 1e-9 {
            return .raiseRamp(ceiling)
        }
        return .leave
    }

    /// Linear ramp sample; `progress` 0…1 → from…to (clamped).
    static func rampOutputGainDB(from: Double, to: Double, progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return from + (to - from) * t
    }

    /// After a band edit. With auto on: immediate lower if above ceiling; raise is reported as ramp target
    /// (caller animates). `outputGainDB` in the result is the value to apply *now* (current, or lowered).
    static func applyBandChange(
        bands: [EQBand],
        outputGainDB: Double,
        sampleRate: Double,
        autoOutputGain: Bool
    ) -> (
        outputGainDB: Double,
        peakBoostDB: Double,
        clippingWarning: Bool,
        autoAdjustment: AutoGainAdjustment
    ) {
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate)
        guard autoOutputGain else {
            return (
                outputGainDB,
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .leave
            )
        }
        let adjustment = autoGainAdjustment(
            currentOutputGainDB: outputGainDB,
            peakBoostDB: boost
        )
        switch adjustment {
        case .leave:
            return (
                outputGainDB,
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .leave
            )
        case .lowerImmediate(let target):
            return (
                target,
                boost,
                isClippingRisk(outputGainDB: target, peakBoostDB: boost),
                .lowerImmediate(target)
            )
        case .raiseRamp(let target):
            // Keep current until the caller ramps; still report the ramp end value.
            return (
                outputGainDB,
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .raiseRamp(target)
            )
        }
    }

    /// Manual output-gain edit: keep the user’s value; warn only on real clipping risk.
    static func applyManualOutputGain(
        requested: Double,
        bands: [EQBand],
        sampleRate: Double
    ) -> (outputGainDB: Double, peakBoostDB: Double, clippingWarning: Bool) {
        let clamped = min(maxOutputGainDB, max(minOutputGainDB, requested))
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate)
        let warning = isClippingRisk(outputGainDB: clamped, peakBoostDB: boost)
        return (clamped, boost, warning)
    }

    /// “Set safe” without enabling Auto. Same path as Auto: lower immediate, raise via ramp.
    /// `outputGainDB` is the value to apply *now* (current on raise, ceiling on lower/leave).
    static func applySetSafe(
        bands: [EQBand],
        outputGainDB: Double,
        sampleRate: Double
    ) -> (
        outputGainDB: Double,
        peakBoostDB: Double,
        clippingWarning: Bool,
        autoAdjustment: AutoGainAdjustment
    ) {
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate)
        let adjustment = autoGainAdjustment(
            currentOutputGainDB: outputGainDB,
            peakBoostDB: boost
        )
        switch adjustment {
        case .leave:
            return (
                outputGainDB,
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .leave
            )
        case .lowerImmediate(let target):
            return (
                target,
                boost,
                isClippingRisk(outputGainDB: target, peakBoostDB: boost),
                .lowerImmediate(target)
            )
        case .raiseRamp(let target):
            return (
                outputGainDB,
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .raiseRamp(target)
            )
        }
    }

    /// Clear used bands and restore output gain toward 0 dB.
    /// Below 0 → raise ramp to 0; above 0 → immediate 0; already 0 → leave gain.
    static func applyResetBands(
        outputGainDB: Double,
        sampleRate: Double
    ) -> (
        bands: [EQBand],
        outputGainDB: Double,
        peakBoostDB: Double,
        clippingWarning: Bool,
        autoAdjustment: AutoGainAdjustment
    ) {
        let bands: [EQBand] = []
        let boost = peakBoostDB(bands: bands, sampleRate: sampleRate) // flat → 0
        let target = 0.0
        if outputGainDB > target + 1e-9 {
            return (
                bands,
                target,
                boost,
                isClippingRisk(outputGainDB: target, peakBoostDB: boost),
                .lowerImmediate(target)
            )
        }
        if outputGainDB < target - 1e-9 {
            return (
                bands,
                outputGainDB, // hold until ramp
                boost,
                isClippingRisk(outputGainDB: outputGainDB, peakBoostDB: boost),
                .raiseRamp(target)
            )
        }
        return (
            bands,
            target,
            boost,
            isClippingRisk(outputGainDB: target, peakBoostDB: boost),
            .leave
        )
    }
}

/// Realtime PEQ cascade (up to 10 bands: PK / LS / HS) + output gain for the process-tap path.
final class PEQProcessor: @unchecked Sendable {
    static let bandCount = EQBand.maxBandCount

    private let lock = NSLock()
    private var bands: [EQBand] = []
    private var sections: [PeakingBiquad] = (0..<bandCount).map { _ in PeakingBiquad() }
    private var sampleRate: Double = 48_000
    private var outputGainDB: Double = 0
    private var outputLinear: Float = 1
    private var bypassBands = false
    /// When bypassing bands, still multiply by output gain (loudness-matched A/B).
    private var applyOutputGainWhenBypassed = true
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
        let newRate = max(sampleRate, 1)
        let newChannels = max(channelCount, 1)
        let mustClear = abs(newRate - self.sampleRate) >= 1e-6 || newChannels != self.channelCount
        self.sampleRate = newRate
        self.channelCount = newChannels
        // Sample-rate / channel changes: clear delay history. Live F/G/Q tweaks must not.
        rebuildSectionsLocked(clearHistory: mustClear)
    }

    func setState(
        bands: [EQBand],
        outputGainDB: Double,
        bypass: Bool,
        applyOutputGainWhenBypassed: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        precondition(bands.count <= Self.bandCount)
        self.bands = bands
        self.outputGainDB = outputGainDB
        self.outputLinear = Float(pow(10.0, outputGainDB / 20.0))
        self.bypassBands = bypass
        self.applyOutputGainWhenBypassed = applyOutputGainWhenBypassed
        // Keep biquad history across coefficient updates so graph-drag stays crackle-free.
        rebuildSectionsLocked(clearHistory: false)
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

    /// Cascade bands (unless bypassed). Output gain applies unless bypassed with match off.
    func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        let bypass = bypassBands
        let applyGain = !bypass || applyOutputGainWhenBypassed
        let gain = applyGain ? outputLinear : 1
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
        let applyGain = !bypass || applyOutputGainWhenBypassed
        let gain = applyGain ? outputLinear : 1
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

    private func rebuildSectionsLocked(clearHistory: Bool) {
        while sections.count < Self.bandCount {
            sections.append(PeakingBiquad())
        }
        for i in 0..<Self.bandCount {
            let section = sections[i]
            if i < bands.count {
                let band = bands[i]
                section.configure(
                    sampleRate: sampleRate,
                    frequency: band.frequencyHz,
                    q: band.q,
                    filterType: band.filterType,
                    clearHistory: clearHistory
                )
                section.setGainDB(band.isAudiblyFlat ? 0 : band.gainDB)
            } else {
                section.configure(
                    sampleRate: sampleRate,
                    frequency: 1_000,
                    q: 1.41,
                    filterType: .peaking,
                    clearHistory: clearHistory
                )
                section.setGainDB(0)
            }
            if clearHistory {
                section.resetState(channelCount: channelCount)
            }
        }
    }
}
