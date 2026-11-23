import Foundation

/// One biquad section, normalized so a0 = 1.
struct BiquadCoefficients: Equatable, Sendable {
    var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

    static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ cookbook design of `band` at `sampleRate` (Q floored at 0.1).
    init(rbj band: EQBand, sampleRate: Double) {
        let c = PeakingBiquad.coefficients(
            filterType: band.filterType, centerHz: band.frequencyHz, gainDB: band.gainDB,
            q: band.q, sampleRate: sampleRate
        )
        self.init(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2)
    }

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    func magnitudeDB(atHz hz: Double, sampleRate: Double) -> Double {
        PeakingBiquad.magnitudeDB(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2, atHz: hz, sampleRate: sampleRate)
    }
}

/// RBJ cookbook biquad (peaking / low-shelf / high-shelf) with Double coeffs, Float samples.
final class PeakingBiquad: @unchecked Sendable {
    static let defaultFrequency: Double = 1_000
    static let defaultQ: Double = 1.41
    /// Treat |gain| below this as bypass (audibly identical to dry).
    static let bypassThresholdDB: Double = 0.05

    private let lock = NSLock()
    private var sampleRate: Double = 48_000
    private var frequency: Double = PeakingBiquad.defaultFrequency
    private var q: Double = PeakingBiquad.defaultQ
    private var gainDB: Double = 0
    private var filterType: EQFilterType = .peaking
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    /// Coefficients set directly (`configure(sampleRate:coefficients:gainDB:)`); nil = RBJ.
    private var fixedCoefficients: BiquadCoefficients?
    private var x1: [Double] = []
    private var x2: [Double] = []
    private var y1: [Double] = []
    private var y2: [Double] = []

    var isBypassed: Bool {
        lock.lock(); defer { lock.unlock() }
        return abs(gainDB) < Self.bypassThresholdDB
    }

    /// Update coefficients. Pass `clearHistory: true` only on sample-rate / channel changes —
    /// clearing on every F/G tweak causes zipper crackle while dragging graph handles.
    func configure(
        sampleRate: Double,
        frequency: Double = PeakingBiquad.defaultFrequency,
        q: Double = PeakingBiquad.defaultQ,
        filterType: EQFilterType = .peaking,
        clearHistory: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        let newRate = max(sampleRate, 1)
        let rateChanged = abs(newRate - self.sampleRate) >= 1e-6
        self.sampleRate = newRate
        self.frequency = frequency
        self.q = max(q, 0.1)
        self.filterType = filterType
        fixedCoefficients = nil
        recalculateLocked()
        if clearHistory || rateChanged {
            resetStateLocked(channelCount: max(x1.count, 2))
        }
    }

    /// Run `coefficients` as given (e.g. a band redesigned for the live rate). `gainDB` is the
    /// band's set gain; it only decides bypass (|gain| < `bypassThresholdDB` → dry).
    func configure(
        sampleRate: Double,
        coefficients: BiquadCoefficients,
        gainDB: Double,
        clearHistory: Bool = false
    ) {
        lock.lock()
        defer { lock.unlock() }
        let newRate = max(sampleRate, 1)
        let rateChanged = abs(newRate - self.sampleRate) >= 1e-6
        self.sampleRate = newRate
        self.gainDB = gainDB
        fixedCoefficients = coefficients
        recalculateLocked()
        if clearHistory || rateChanged {
            resetStateLocked(channelCount: max(x1.count, 2))
        }
    }

    func setGainDB(_ gainDB: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.gainDB = gainDB
        recalculateLocked()
    }

    func resetState(channelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        resetStateLocked(channelCount: channelCount)
    }

    /// Realtime-safe: process interleaved float PCM in place (no heap allocation).
    func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, channels > 0 else { return }
        if x1.count != channels {
            resetStateLocked(channelCount: channels)
        }
        if abs(gainDB) < Self.bypassThresholdDB { return }

        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        for i in 0..<frames {
            for ch in 0..<channels {
                let index = i * channels + ch
                let x0 = Double(samples[index])
                let y0 = b0 * x0 + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch]
                x2[ch] = x1[ch]; x1[ch] = x0
                y2[ch] = y1[ch]; y1[ch] = y0
                samples[index] = Float(y0)
            }
        }
    }

    /// Realtime-safe: process one planar float channel in place.
    func processChannel(_ samples: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, channel >= 0 else { return }
        if channel >= x1.count {
            resetStateLocked(channelCount: channel + 1)
        }
        if abs(gainDB) < Self.bypassThresholdDB { return }

        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        var x1v = x1[channel], x2v = x2[channel], y1v = y1[channel], y2v = y2[channel]
        for i in 0..<frames {
            let x0 = Double(samples[i])
            let y0 = b0 * x0 + b1 * x1v + b2 * x2v - a1 * y1v - a2 * y2v
            x2v = x1v; x1v = x0
            y2v = y1v; y1v = y0
            samples[i] = Float(y0)
        }
        x1[channel] = x1v; x2[channel] = x2v; y1[channel] = y1v; y2[channel] = y2v
    }

    /// Test helper: magnitude response in dB at `hz` (analytical from coeffs).
    func magnitudeDB(atHz hz: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return Self.magnitudeDB(
            b0: b0, b1: b1, b2: b2, a1: a1, a2: a2,
            atHz: hz,
            sampleRate: sampleRate
        )
    }

    /// Analytical magnitude for any supported filter type (headroom / graph / tests).
    static func magnitudeDB(
        filterType: EQFilterType,
        centerHz: Double,
        gainDB: Double,
        q: Double,
        atHz: Double,
        sampleRate: Double
    ) -> Double {
        let c = coefficients(
            filterType: filterType,
            centerHz: centerHz,
            gainDB: gainDB,
            q: q,
            sampleRate: sampleRate
        )
        return magnitudeDB(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2, atHz: atHz, sampleRate: sampleRate)
    }

    static func magnitudeDB(
        b0: Double, b1: Double, b2: Double, a1: Double, a2: Double,
        atHz: Double,
        sampleRate: Double
    ) -> Double {
        let sr = max(sampleRate, 1)
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

    /// RBJ cookbook coefficients normalized so a0 = 1.
    static func coefficients(
        filterType: EQFilterType,
        centerHz: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        let sr = max(sampleRate, 1)
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * centerHz / sr
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * max(q, 0.1))

        let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch filterType {
        case .peaking:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosw0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosw0
            a2 = 1.0 - alpha / A
        case .lowShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1) - (A + 1) * cosw0)
            b2 = A * ((A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = -2.0 * ((A - 1) + (A + 1) * cosw0)
            a2 = (A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha
        case .highShelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1) + (A - 1) * cosw0 + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1) + (A + 1) * cosw0)
            b2 = A * ((A + 1) + (A - 1) * cosw0 - twoSqrtAAlpha)
            a0 = (A + 1) - (A - 1) * cosw0 + twoSqrtAAlpha
            a1 = 2.0 * ((A - 1) - (A + 1) * cosw0)
            a2 = (A + 1) - (A - 1) * cosw0 - twoSqrtAAlpha
        }
        return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)
    }

    private func resetStateLocked(channelCount: Int) {
        let count = max(channelCount, 1)
        x1 = Array(repeating: 0, count: count)
        x2 = Array(repeating: 0, count: count)
        y1 = Array(repeating: 0, count: count)
        y2 = Array(repeating: 0, count: count)
    }

    private func recalculateLocked() {
        if let fixed = fixedCoefficients {
            b0 = fixed.b0; b1 = fixed.b1; b2 = fixed.b2; a1 = fixed.a1; a2 = fixed.a2
            return
        }
        let c = Self.coefficients(
            filterType: filterType,
            centerHz: frequency,
            gainDB: gainDB,
            q: q,
            sampleRate: sampleRate
        )
        b0 = c.b0
        b1 = c.b1
        b2 = c.b2
        a1 = c.a1
        a2 = c.a2
    }
}
