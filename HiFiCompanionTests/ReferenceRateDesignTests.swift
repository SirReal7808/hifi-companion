import XCTest


final class ReferenceRateDesignTests: XCTestCase {
    /// Mert's "Bunny" curve, tuned by ear at 44.1 kHz (2026-11-23).
    private let bunny: [EQBand] = {
        [
            (EQFilterType.lowShelf, 140.0, -2.7, 0.5),
            (.peaking, 570, 1.6, 0.6),
            (.peaking, 1_700, -1.9, 1.3),
            (.peaking, 3_100, 3.3, 1.7),
            (.peaking, 7_100, -7, 1.1),
            (.peaking, 9_300, 9.2, 2),
            (.peaking, 12_000, -14, 4.5),
        ].map { type, hz, gain, q in
            var band = EQBand.makeBand(frequencyHz: hz, filterType: type, gainDB: gain, q: q)
            band.enabled = true
            return band
        }
    }()

    /// Denser than the fit grid (160 points) so a miss between fit points shows.
    private let grid: [Double] = (0..<1_000).map { 20 * pow(1_000, Double($0) / 999) }

    private func sections(_ bands: [EQBand], at rate: Double, matched: Bool) -> [BiquadCoefficients] {
        let live = bands.filter { !$0.isAudiblyFlat }
        return matched
            ? ReferenceRateDesign.coefficients(live, sampleRate: rate)
            : live.map { BiquadCoefficients(rbj: $0, sampleRate: rate) }
    }

    private func maxDifference(_ bands: [EQBand], designedAt rate: Double, matched: Bool) -> Double {
        let run = sections(bands, at: rate, matched: matched)
        return grid.map { hz in
            abs(
                PEQHeadroom.cascadeMagnitudeDB(sections: run, atHz: hz, sampleRate: rate)
                    - PEQHeadroom.cascadeMagnitudeDB(bands: bands, atHz: hz, sampleRate: 44_100)
            )
        }.max() ?? 0
    }

    func testBunnyAtHighRatesMatchesTheCurveTunedAt441() {
        for rate in [48_000.0, 88_200, 96_000, 176_400, 192_000] {
            XCTAssertLessThan(maxDifference(bunny, designedAt: rate, matched: true), 0.12, "rate \(rate)")
        }
        // Plain RBJ at 96 kHz was off by more than 2 dB; the closed form alone by ≈ 0.6 dB.
        XCTAssertGreaterThan(maxDifference(bunny, designedAt: 96_000, matched: false), 2)
        let closedForm = bunny.map { ReferenceRateDesign.closedFormBand($0, sampleRate: 96_000) }
        let closedFormDiff = grid.map { hz in
            abs(
                PEQHeadroom.cascadeMagnitudeDB(bands: closedForm, atHz: hz, sampleRate: 96_000)
                    - PEQHeadroom.cascadeMagnitudeDB(bands: bunny, atHz: hz, sampleRate: 44_100)
            )
        }.max() ?? 0
        XCTAssertGreaterThan(closedFormDiff, 0.4)
    }

    func testFittedSectionsAreStableAndQuietAbove20k() {
        for rate in [48_000.0, 96_000, 192_000] {
            for c in sections(bunny, at: rate, matched: true) {
                // Stable: both poles inside the unit circle (stability triangle).
                XCTAssertLessThan(abs(c.a2), 1)
                XCTAssertLessThan(abs(c.a1), 1 + c.a2)
            }
            let run = sections(bunny, at: rate, matched: true)
            for hz in stride(from: 20_000.0, to: rate * 0.5, by: 250) {
                XCTAssertLessThan(abs(PEQHeadroom.cascadeMagnitudeDB(sections: run, atHz: hz, sampleRate: rate)), 1, "\(hz) @\(rate)")
            }
        }
    }

    func testHighShelfNearTheTopMatches() {
        var shelf = EQBand.makeBand(frequencyHz: 10_000, filterType: .highShelf, gainDB: 6, q: 0.707)
        shelf.enabled = true
        let plain = maxDifference([shelf], designedAt: 96_000, matched: false)
        let matched = maxDifference([shelf], designedAt: 96_000, matched: true)
        XCTAssertLessThan(matched, 0.3)
        XCTAssertLessThan(matched, plain)
    }

    func testRatesAtOrBelow441AreUnchanged() {
        let bands = bunny
        for rate in [32_000.0, 44_100] {
            XCTAssertEqual(
                ReferenceRateDesign.coefficients(bands, sampleRate: rate),
                bands.map { BiquadCoefficients(rbj: $0, sampleRate: rate) }
            )
        }
    }

    func testPeakCentreGainAndIdentityAreKept() {
        let bands = bunny
        let designed = bands.map { ReferenceRateDesign.closedFormBand($0, sampleRate: 96_000) }
        for (a, b) in zip(bands, designed) {
            XCTAssertEqual(a.id, b.id)
            XCTAssertEqual(a.gainDB, b.gainDB)
            XCTAssertEqual(a.filterType, b.filterType)
        }
        // Low bands are untouched in practice.
        XCTAssertEqual(designed[1].frequencyHz, 570, accuracy: 1)
        XCTAssertEqual(designed[1].q, 0.6, accuracy: 0.01)
    }

    func testEdgeBandsNeverMatchWorseThanAsSet() {
        let cases: [(EQFilterType, Double, Double, Double)] = [
            (.peaking, 20_000, 6, 0.1), (.peaking, 12_000, 6, 0.5), (.peaking, 19_500, -8, 10),
            (.highShelf, 15_000, 12, 2), (.highShelf, 10_000, 6, 4), (.lowShelf, 8_000, -6, 0.7),
        ]
        for (type, hz, gain, q) in cases {
            var band = EQBand.makeBand(frequencyHz: hz, filterType: type, gainDB: gain, q: q)
            band.enabled = true
            for rate in [48_000.0, 96_000, 192_000] {
                let c = ReferenceRateDesign.coefficients(band, sampleRate: rate)
                XCTAssertTrue([c.b0, c.b1, c.b2, c.a1, c.a2].allSatisfy(\.isFinite))
                XCTAssertLessThan(abs(c.a2), 1)
                XCTAssertLessThan(abs(c.a1), 1 + c.a2)
                XCTAssertLessThanOrEqual(
                    maxDifference([band], designedAt: rate, matched: true),
                    maxDifference([band], designedAt: rate, matched: false) + 1e-9,
                    "\(type) \(hz) Q\(q) @\(rate)"
                )
            }
        }
    }

    func testFlatAndDisabledBandsPassThroughInOrder() {
        var off = EQBand.makeBand(frequencyHz: 9_000, filterType: .peaking, gainDB: 6, q: 2)
        off.enabled = false
        var flat = EQBand.makeBand(frequencyHz: 11_000, filterType: .peaking, gainDB: 0, q: 3)
        flat.enabled = true
        var live = EQBand.makeBand(frequencyHz: 10_000, filterType: .peaking, gainDB: 6, q: 2)
        live.enabled = true
        let designed = ReferenceRateDesign.coefficients([off, flat, live], sampleRate: 96_000)
        XCTAssertEqual(designed.count, 3)
        XCTAssertEqual(designed[0], BiquadCoefficients(rbj: off, sampleRate: 96_000))
        XCTAssertEqual(designed[1], BiquadCoefficients(rbj: flat, sampleRate: 96_000))
        XCTAssertNotEqual(designed[2], BiquadCoefficients(rbj: live, sampleRate: 96_000))
    }

    func testProcessorRunsDesignedBandsWhicheverComesFirst() {
        let a = PEQProcessor()
        a.setState(bands: bunny, outputGainDB: 0, bypass: false)
        a.configure(sampleRate: 96_000, channelCount: 2)
        let b = PEQProcessor()
        b.configure(sampleRate: 96_000, channelCount: 2)
        b.setState(bands: bunny, outputGainDB: 0, bypass: false)
        let expected = ReferenceRateDesign.coefficients(bunny, sampleRate: 96_000)
        XCTAssertEqual(a.runningCoefficients, expected)
        XCTAssertEqual(b.runningCoefficients, expected)
        a.configure(sampleRate: 44_100, channelCount: 2)
        XCTAssertEqual(a.runningCoefficients, bunny.map { BiquadCoefficients(rbj: $0, sampleRate: 44_100) })
    }

    func testProcessorOutputFollowsTheFittedCurve() {
        // A 9.3 kHz sine through the processor at 96 kHz comes out at the 44.1 kHz curve's level.
        let p = PEQProcessor()
        p.configure(sampleRate: 96_000, channelCount: 1)
        p.setState(bands: bunny, outputGainDB: 0, bypass: false)
        let hz = 9_300.0, frames = 96_000
        var buffer = (0..<frames).map { Float(sin(2 * Double.pi * hz * Double($0) / 96_000)) }
        buffer.withUnsafeMutableBufferPointer { p.processInterleaved($0.baseAddress!, frames: frames, channels: 1) }
        let tail = buffer[(frames / 2)...].map { Double($0) * Double($0) }
        let rmsDB = 10 * log10(tail.reduce(0, +) / Double(tail.count) * 2)
        let expected = PEQHeadroom.cascadeMagnitudeDB(bands: bunny, atHz: hz, sampleRate: 44_100)
        XCTAssertEqual(rmsDB, expected, accuracy: 0.15)
    }
}
