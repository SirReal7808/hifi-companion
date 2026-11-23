import Foundation

/// Makes a curve sound the same at every sample rate: the curve the user sets (and hears at
/// 44.1 kHz) is reproduced at 48 / 88.2 / 96 / 192 kHz.
///
/// RBJ biquads designed at the live rate bend the top octave differently per rate (bilinear
/// warping): Mert's "Bunny" curve, tuned by ear at 44.1 kHz, differed by up to 2.2 dB at 96 kHz
/// around 9–12 kHz (2026-11-23). Here each band is redesigned for the live rate so its response
/// matches the same band designed at 44.1 kHz:
/// - Peaking: closed form. A 44.1 kHz RBJ peak is the analog prototype on warped frequency, so its
///   mid-gain (½ dB) edges are known exactly; the live-rate band gets the centre and Q whose edges
///   land on the same physical frequencies. Gain is unchanged.
/// - Shelves: the mid-gain point is the corner frequency at every rate, so the corner stays; only
///   Q is fitted (golden-section search on the dB error over 20 Hz…20 kHz).
/// Rates at or below 44.1 kHz use the band as set, and so does any band the match would not bring
/// closer (max dB error over 20 Hz…20 kHz).
enum ReferenceRateDesign {
    static let referenceSampleRate: Double = 44_100

    /// The band to run at `sampleRate` (frequency / Q adjusted; id, gain, type, enabled kept).
    static func designed(_ band: EQBand, sampleRate: Double) -> EQBand {
        guard sampleRate > referenceSampleRate + 0.5, !band.isAudiblyFlat else { return band }
        var out = band
        switch band.filterType {
        case .peaking:
            guard let match = peakingMatch(frequencyHz: band.frequencyHz, q: band.q, sampleRate: sampleRate) else {
                return band
            }
            out.frequencyHz = match.frequencyHz
            out.q = match.q
        case .lowShelf:
            // Well below the top octave a low shelf is already identical at every rate.
            guard band.frequencyHz >= 2_000 else { return band }
            out.q = shelfQ(band, sampleRate: sampleRate)
        case .highShelf:
            out.q = shelfQ(band, sampleRate: sampleRate)
        }
        // A very wide band near the top (e.g. Q 0.1 at 20 kHz) or a resonant shelf can match
        // worse than the band as set; keep whichever is closer to the 44.1 kHz curve.
        let reference = curve(band, sampleRate: referenceSampleRate)
        return maxError(out, sampleRate: sampleRate, reference: reference)
            < maxError(band, sampleRate: sampleRate, reference: reference) ? out : band
    }

    private static func curve(_ band: EQBand, sampleRate: Double) -> [Double] {
        let c = PeakingBiquad.coefficients(
            filterType: band.filterType, centerHz: band.frequencyHz, gainDB: band.gainDB,
            q: max(band.q, 0.1), sampleRate: sampleRate
        )
        return checkGrid.map {
            PeakingBiquad.magnitudeDB(b0: c.b0, b1: c.b1, b2: c.b2, a1: c.a1, a2: c.a2, atHz: $0, sampleRate: sampleRate)
        }
    }

    private static func maxError(_ band: EQBand, sampleRate: Double, reference: [Double]) -> Double {
        zip(curve(band, sampleRate: sampleRate), reference).map { abs($0 - $1) }.max() ?? 0
    }

    static func designed(_ bands: [EQBand], sampleRate: Double) -> [EQBand] {
        guard sampleRate > referenceSampleRate + 0.5 else { return bands }
        return bands.map { designed($0, sampleRate: sampleRate) }
    }

    /// Peaking band whose mid-gain edges at `sampleRate` sit where the 44.1 kHz band's do.
    static func peakingMatch(frequencyHz: Double, q: Double, sampleRate: Double) -> (frequencyHz: Double, q: Double)? {
        let ref = referenceSampleRate
        let q = max(q, 0.1)
        guard frequencyHz > 0, frequencyHz < ref * 0.5 * 0.999 else { return nil }
        // Analog prototype (centre 1): mid-gain edges satisfy |1 − Ω²| = Ω / Q → lo · hi = 1, hi − lo = 1 / Q.
        let half = 1 / (2 * q)
        let loEdge = -half + (half * half + 1).squareRoot()
        let hiEdge = loEdge + 1 / q
        // 44.1 kHz bilinear map: Ω = tan(π f / fs) / tan(π f0 / fs).
        let k = tan(Double.pi * frequencyHz / ref)
        let loHz = ref / Double.pi * atan(loEdge * k)
        let hiHz = ref / Double.pi * atan(hiEdge * k)
        let wLo = tan(Double.pi * loHz / sampleRate)
        let wHi = tan(Double.pi * hiHz / sampleRate)
        guard wLo > 0, wHi > wLo else { return nil }
        let w0 = (wLo * wHi).squareRoot()
        let centre = sampleRate / Double.pi * atan(w0)
        let newQ = w0 / (wHi - wLo)
        guard centre.isFinite, newQ.isFinite, newQ > 0 else { return nil }
        return (centre, newQ)
    }

    /// Q at `sampleRate` (corner kept) that best matches the 44.1 kHz shelf.
    static func shelfQ(_ band: EQBand, sampleRate: Double) -> Double {
        let ref = referenceSampleRate
        let q = max(band.q, 0.1)
        let c = shelfGrid
        var target = [Double](repeating: 0, count: c.count)
        for i in c.indices {
            target[i] = PeakingBiquad.magnitudeDB(
                filterType: band.filterType, centerHz: band.frequencyHz, gainDB: band.gainDB,
                q: q, atHz: c[i], sampleRate: ref
            )
        }
        func error(_ logQ: Double) -> Double {
            let coeffs = PeakingBiquad.coefficients(
                filterType: band.filterType, centerHz: band.frequencyHz, gainDB: band.gainDB,
                q: exp(logQ), sampleRate: sampleRate
            )
            var sum = 0.0
            for i in c.indices {
                let d = PeakingBiquad.magnitudeDB(
                    b0: coeffs.b0, b1: coeffs.b1, b2: coeffs.b2, a1: coeffs.a1, a2: coeffs.a2,
                    atHz: c[i], sampleRate: sampleRate
                ) - target[i]
                sum += d * d
            }
            return sum
        }
        // Golden-section search on log Q within ×/÷ 4 of the set Q.
        let ratio = (5.0.squareRoot() - 1) / 2
        var lo = log(q) - log(4.0)
        var hi = log(q) + log(4.0)
        var x1 = hi - ratio * (hi - lo)
        var x2 = lo + ratio * (hi - lo)
        var e1 = error(x1)
        var e2 = error(x2)
        for _ in 0..<40 {
            if e1 < e2 {
                hi = x2; x2 = x1; e2 = e1
                x1 = hi - ratio * (hi - lo); e1 = error(x1)
            } else {
                lo = x1; x1 = x2; e1 = e2
                x2 = lo + ratio * (hi - lo); e2 = error(x2)
            }
        }
        return exp((lo + hi) / 2)
    }

    /// Dense 20 Hz…20 kHz grid for the keep-or-match check (resonant bands peak between points).
    private static let checkGrid: [Double] = (0..<200).map { i in
        20 * pow(1_000, Double(i) / 199)
    }

    /// 20 Hz…20 kHz, log-spaced (where the 44.1 kHz reference is defined and audible).
    private static let shelfGrid: [Double] = (0..<64).map { i in
        20 * pow(1_000, Double(i) / 63)
    }
}
