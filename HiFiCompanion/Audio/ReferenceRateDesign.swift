import Foundation

/// Makes a curve sound the same at every sample rate: the curve the user sets (and hears at
/// 44.1 kHz) is reproduced at 48 / 88.2 / 96 / 192 kHz.
///
/// RBJ biquads designed at the live rate bend the top octave differently per rate (bilinear
/// warping): Mert's "Bunny" curve, tuned by ear at 44.1 kHz, differed by up to 2.2 dB at 96 kHz
/// around 9–12 kHz (2026-11-23). Above 44.1 kHz each band is redesigned for the live rate in two
/// steps:
/// 1. Closed form (`closedFormBand`), still an RBJ band:
///    - Peaking: a 44.1 kHz RBJ peak is the analog prototype on warped frequency, so its
///      mid-gain (½ dB) edges are known exactly; the live-rate band gets the centre and Q whose
///      edges land on the same physical frequencies. Gain is unchanged.
///    - Shelves: the mid-gain point is the corner frequency at every rate, so the corner stays;
///      only Q is fitted (golden-section search on the dB error over 20 Hz…20 kHz).
///    This left ≈ 0.6 dB on Bunny at 96 kHz, still audible: a 44.1 kHz peak near the top is
///    asymmetric (its upper flank is squeezed toward 22.05 kHz) and an RBJ peak at 96 kHz is not.
/// 2. Free fit (`fittedCoefficients`): a general biquad (gain + numerator + denominator, five
///    numbers) is fitted to the 44.1 kHz band's magnitude over 20 Hz…20 kHz (Levenberg–Marquardt
///    on dB, reweighted toward the smallest maximum error), seeded with step 1. Poles and zeros
///    stay inside the unit circle by construction, so the section is stable and minimum-phase.
///    Above 20 kHz (inaudible, and undefined at 44.1 kHz) the fit is held near step 1's shape so
///    it cannot boost ultrasonics. Bunny lands within ≈ 0.1 dB at every rate.
/// Each step is kept only if it is closer to the 44.1 kHz band (max dB error over 20 Hz…20 kHz)
/// than what came before; rates at or below 44.1 kHz run the band as set.
enum ReferenceRateDesign {
    static let referenceSampleRate: Double = 44_100

    /// The section to run for `band` at `sampleRate`. Cached per (band settings, rate): the fit
    /// takes about a millisecond and the graph / headroom ask for every band on each edit.
    static func coefficients(_ band: EQBand, sampleRate: Double) -> BiquadCoefficients {
        guard sampleRate > referenceSampleRate + 0.5, !band.isAudiblyFlat else {
            return BiquadCoefficients(rbj: band, sampleRate: sampleRate)
        }
        let key = CacheKey(band: band, sampleRate: sampleRate)
        if let hit = cache.value(for: key) { return hit }
        let seed = BiquadCoefficients(rbj: closedFormBand(band, sampleRate: sampleRate), sampleRate: sampleRate)
        var result = seed
        if let fit = fittedCoefficients(band, sampleRate: sampleRate, seed: seed) {
            // The fit is judged on its own (coarser) grid; confirm on the dense one so a narrow
            // band near the top is never run worse than the closed form.
            let reference = curve(BiquadCoefficients(rbj: band, sampleRate: referenceSampleRate), referenceSampleRate)
            if maxError(fit, sampleRate, reference) < maxError(seed, sampleRate, reference) { result = fit }
        }
        cache.store(result, for: key)
        return result
    }

    static func coefficients(_ bands: [EQBand], sampleRate: Double) -> [BiquadCoefficients] {
        bands.map { coefficients($0, sampleRate: sampleRate) }
    }

    /// Step 1: the RBJ band to run at `sampleRate` (frequency / Q adjusted; id, gain, type,
    /// enabled kept).
    static func closedFormBand(_ band: EQBand, sampleRate: Double) -> EQBand {
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
        let reference = curve(BiquadCoefficients(rbj: band, sampleRate: referenceSampleRate), referenceSampleRate)
        return maxError(BiquadCoefficients(rbj: out, sampleRate: sampleRate), sampleRate, reference)
            < maxError(BiquadCoefficients(rbj: band, sampleRate: sampleRate), sampleRate, reference) ? out : band
    }

    private static func curve(_ c: BiquadCoefficients, _ sampleRate: Double) -> [Double] {
        checkGrid.map { c.magnitudeDB(atHz: $0, sampleRate: sampleRate) }
    }

    private static func maxError(_ c: BiquadCoefficients, _ sampleRate: Double, _ reference: [Double]) -> Double {
        zip(curve(c, sampleRate), reference).map { abs($0 - $1) }.max() ?? 0
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

    // MARK: - Step 2: free biquad fit

    /// Weight of the above-20 kHz points that hold the fit near the seed's shape.
    private static let ultrasonicWeight = 0.3
    /// Most the fit may differ from the seed above 20 kHz.
    private static let ultrasonicMarginDB = 1.0
    /// Largest |reflection coefficient|: keeps poles at radius ≤ ≈ 0.99995.
    private static let maxReflection = 0.9999

    /// A general biquad closer to the 44.1 kHz band than `seed`, or nil if the fit is not
    /// closer (max dB error over 20 Hz…20 kHz) or would lift the response above 20 kHz by more
    /// than `ultrasonicMarginDB` over the seed (checked up to Nyquist: headroom reads there).
    static func fittedCoefficients(_ band: EQBand, sampleRate: Double, seed: BiquadCoefficients) -> BiquadCoefficients? {
        let nyquist = sampleRate * 0.5 - 1
        guard nyquist > 20_000 else { return nil }
        let reference = BiquadCoefficients(rbj: band, sampleRate: referenceSampleRate)
        let audibleCount = fitGrid.count
        let ultraHz: [Double] = (1...32).map { 20_000 * pow(nyquist / 20_000, Double($0) / 32) }
        let grid = Grid(hz: fitGrid + ultraHz, sampleRate: sampleRate)
        var target = fitGrid.map { reference.magnitudeDB(atHz: $0, sampleRate: referenceSampleRate) }
        target += ultraHz.map { seed.magnitudeDB(atHz: $0, sampleRate: sampleRate) }
        var weights = [Double](repeating: 1, count: audibleCount)
            + [Double](repeating: ultrasonicWeight, count: ultraHz.count)
        var problem = FitProblem(grid: grid, target: target, weights: weights)

        func maxAudibleError(_ c: BiquadCoefficients, _ errors: inout [Double]) -> Double {
            grid.magnitudeDB(c, into: &problem.scratch)
            var worst = 0.0
            for i in 0..<audibleCount {
                errors[i] = abs(problem.scratch[i] - target[i])
                worst = max(worst, errors[i])
            }
            return worst
        }

        guard var p = Params(seed) else { return nil }
        var errors = [Double](repeating: 0, count: audibleCount)
        let seedError = maxAudibleError(seed, &errors)
        var best: (coefficients: BiquadCoefficients, error: Double)?
        // Least squares, then reweight toward the points with the largest error (Lawson), so
        // the result approaches the smallest maximum error rather than the smallest mean.
        for _ in 0..<6 {
            p = levenbergMarquardt(p, problem: &problem)
            let c = p.coefficients
            let worst = maxAudibleError(c, &errors)
            if worst < (best?.error ?? seedError) { best = (c, worst) }
            let mean = errors.reduce(0, +) / Double(audibleCount)
            guard mean > 1e-9 else { break }
            var norm = 0.0
            for i in 0..<audibleCount {
                weights[i] *= (max(errors[i], 1e-9) / mean).squareRoot()
                norm += weights[i]
            }
            norm /= Double(audibleCount)
            for i in 0..<audibleCount { weights[i] /= norm }
            problem.weights = weights
        }
        guard let fit = best?.coefficients else { return nil }
        // Above 20 kHz stay within the margin of the seed, on a dense grid up to Nyquist.
        let checkHz = (0...400).map { 20_000 * pow(nyquist / 20_000, Double($0) / 400) }
        for hz in checkHz {
            let f = fit.magnitudeDB(atHz: hz, sampleRate: sampleRate)
            let s = seed.magnitudeDB(atHz: hz, sampleRate: sampleRate)
            guard f.isFinite, abs(f - s) <= ultrasonicMarginDB else { return nil }
        }
        return fit
    }

    /// Weighted dB residuals of a candidate against the target, with reusable buffers.
    private struct FitProblem {
        let grid: Grid
        let target: [Double]
        var weights: [Double]
        var scratch: [Double]

        init(grid: Grid, target: [Double], weights: [Double]) {
            self.grid = grid
            self.target = target
            self.weights = weights
            scratch = [Double](repeating: 0, count: target.count)
        }

        /// Writes the residuals into `r` and returns their sum of squares.
        mutating func residuals(_ v: [Double], into r: inout [Double]) -> Double {
            grid.magnitudeDB(Params(values: v).coefficients, into: &scratch)
            var sum = 0.0
            for i in r.indices {
                r[i] = (scratch[i] - target[i]) * weights[i]
                sum += r[i] * r[i]
            }
            return sum
        }
    }

    /// Five free parameters mapped onto every stable, minimum-phase biquad: numerator and
    /// denominator are 1 + c1 z⁻¹ + c2 z⁻² with c2 = k2, c1 = k1 (1 + k2), k = tanh(u) scaled
    /// below 1 (reflection coefficients), times a gain e^g.
    private struct Params {
        var v: [Double] // u1, u2 (zeros), v1, v2 (poles), g

        init(values: [Double]) { v = values }

        init?(_ c: BiquadCoefficients) {
            var b0 = c.b0, b2 = c.b2
            // Zeros outside the unit circle → their mirror image (same magnitude).
            if abs(b2) > abs(b0) { swap(&b0, &b2) }
            guard abs(b0) > 1e-12 else { return nil }
            let zeros = Self.unmap(c.b1 / b0, b2 / b0)
            let poles = Self.unmap(c.a1, c.a2)
            v = [zeros.0, zeros.1, poles.0, poles.1, log(abs(b0))]
            guard v.allSatisfy(\.isFinite) else { return nil }
        }

        var coefficients: BiquadCoefficients {
            let n = Self.map(v[0], v[1]), d = Self.map(v[2], v[3]), g = exp(v[4])
            return BiquadCoefficients(b0: g, b1: g * n.0, b2: g * n.1, a1: d.0, a2: d.1)
        }

        private static func map(_ u1: Double, _ u2: Double) -> (Double, Double) {
            let k1 = ReferenceRateDesign.maxReflection * tanh(u1)
            let k2 = ReferenceRateDesign.maxReflection * tanh(u2)
            return (k1 * (1 + k2), k2)
        }

        private static func unmap(_ c1: Double, _ c2: Double) -> (Double, Double) {
            let m = ReferenceRateDesign.maxReflection * 0.999_999
            let k2 = min(max(c2, -m), m)
            let k1 = min(max(c1 / (1 + k2), -m), m)
            return (atanh(k1 / ReferenceRateDesign.maxReflection), atanh(k2 / ReferenceRateDesign.maxReflection))
        }
    }

    /// Damped Gauss–Newton (numerical Jacobian, 5 × 5 normal equations); buffers allocated once.
    private static func levenbergMarquardt(_ start: Params, problem: inout FitProblem) -> Params {
        let n = 5
        let m = problem.target.count
        var p = start.v
        var r = [Double](repeating: 0, count: m)
        var rq = r
        var jac = [Double](repeating: 0, count: m * n)
        var a = [Double](repeating: 0, count: n * n)
        var g = [Double](repeating: 0, count: n)
        var q = p
        var cost = problem.residuals(p, into: &r)
        var lambda = 1e-3
        for _ in 0..<60 {
            for j in 0..<n {
                q = p
                let h = 1e-6 * max(1, abs(p[j]))
                q[j] += h
                _ = problem.residuals(q, into: &rq)
                for i in 0..<m { jac[i * n + j] = (rq[i] - r[i]) / h }
            }
            for x in 0..<(n * n) { a[x] = 0 }
            for x in 0..<n { g[x] = 0 }
            for i in 0..<m {
                let base = i * n
                for x in 0..<n {
                    let jx = jac[base + x]
                    g[x] -= jx * r[i]
                    for y in x..<n { a[x * n + y] += jx * jac[base + y] }
                }
            }
            for x in 0..<n { for y in 0..<x { a[x * n + y] = a[y * n + x] } }
            var improved = false
            for _ in 0..<10 {
                var mtx = a
                for x in 0..<n { mtx[x * n + x] = mtx[x * n + x] * (1 + lambda) + 1e-12 }
                guard let step = solve(mtx, g, n) else { lambda *= 10; continue }
                for x in 0..<n { q[x] = p[x] + step[x] }
                guard q.allSatisfy(\.isFinite) else { lambda *= 10; continue }
                let c = problem.residuals(q, into: &rq)
                if c < cost {
                    let gain = cost - c
                    p = q; swap(&r, &rq); cost = c
                    lambda = max(lambda / 3, 1e-9)
                    improved = gain > 1e-12 * max(cost, 1e-300)
                    break
                }
                lambda *= 4
            }
            if !improved { break }
        }
        return Params(values: p)
    }

    /// Gaussian elimination with partial pivoting on a row-major n × n matrix; nil if singular.
    private static func solve(_ matrix: [Double], _ rhs: [Double], _ n: Int) -> [Double]? {
        var a = matrix, x = rhs
        for i in 0..<n {
            var pivot = i
            for k in i..<n where abs(a[k * n + i]) > abs(a[pivot * n + i]) { pivot = k }
            guard abs(a[pivot * n + i]) > 1e-300 else { return nil }
            if pivot != i {
                for j in 0..<n { a.swapAt(i * n + j, pivot * n + j) }
                x.swapAt(i, pivot)
            }
            for k in (i + 1)..<n {
                let f = a[k * n + i] / a[i * n + i]
                for j in i..<n { a[k * n + j] -= f * a[i * n + j] }
                x[k] -= f * x[i]
            }
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = x[i]
            for j in (i + 1)..<n { s -= a[i * n + j] * x[j] }
            x[i] = s / a[i * n + i]
        }
        return x
    }

    /// Frequencies with cos ω, cos 2ω precomputed for fast biquad magnitudes.
    private struct Grid {
        let cos1: [Double]
        let cos2: [Double]

        init(hz: [Double], sampleRate: Double) {
            let w = hz.map { 2 * Double.pi * $0 / sampleRate }
            cos1 = w.map(cos)
            cos2 = w.map { cos(2 * $0) }
        }

        func magnitudeDB(_ c: BiquadCoefficients) -> [Double] {
            var out = [Double](repeating: 0, count: cos1.count)
            magnitudeDB(c, into: &out)
            return out
        }

        func magnitudeDB(_ c: BiquadCoefficients, into out: inout [Double]) {
            let n0 = c.b0 * c.b0 + c.b1 * c.b1 + c.b2 * c.b2
            let n1 = 2 * (c.b0 * c.b1 + c.b1 * c.b2)
            let n2 = 2 * c.b0 * c.b2
            let d0 = 1 + c.a1 * c.a1 + c.a2 * c.a2
            let d1 = 2 * (c.a1 + c.a1 * c.a2)
            let d2 = 2 * c.a2
            for i in cos1.indices {
                let num = n0 + n1 * cos1[i] + n2 * cos2[i]
                let den = d0 + d1 * cos1[i] + d2 * cos2[i]
                out[i] = 10 * log10(max(num, 1e-30) / max(den, 1e-30))
            }
        }
    }

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let type: EQFilterType
        let frequencyHz: Double
        let gainDB: Double
        let q: Double
        let sampleRate: Double

        init(band: EQBand, sampleRate: Double) {
            type = band.filterType
            frequencyHz = band.frequencyHz
            gainDB = band.gainDB
            q = band.q
            self.sampleRate = sampleRate
        }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [CacheKey: BiquadCoefficients] = [:]

        func value(for key: CacheKey) -> BiquadCoefficients? {
            lock.lock(); defer { lock.unlock() }
            return entries[key]
        }

        func store(_ value: BiquadCoefficients, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            // Dragging a handle makes a new key per step; start over rather than grow forever.
            if entries.count >= 2_048 { entries.removeAll(keepingCapacity: true) }
            entries[key] = value
        }
    }

    private static let cache = Cache()

    // MARK: - Grids

    /// Dense 20 Hz…20 kHz grid for the keep-or-match checks (a Q 10 band near the top peaks
    /// between the points of a 200-point grid).
    private static let checkGrid: [Double] = (0..<1_000).map { i in
        20 * pow(1_000, Double(i) / 999)
    }

    /// 20 Hz…20 kHz, log-spaced (where the 44.1 kHz reference is defined and audible).
    private static let shelfGrid: [Double] = (0..<64).map { i in
        20 * pow(1_000, Double(i) / 63)
    }

    /// 20 Hz…20 kHz for the free fit.
    private static let fitGrid: [Double] = (0..<160).map { i in
        20 * pow(1_000, Double(i) / 159)
    }
}
