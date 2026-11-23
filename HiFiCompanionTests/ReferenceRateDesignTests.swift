import XCTest


final class ReferenceRateDesignTests: XCTestCase {
    /// Mert's "Bunny" curve, tuned by ear at 44.1 kHz (2026-11-23).
    private let bunny: [EQBand] = {
        [
            (EQFilterType.lowShelf, 140.0, -2.7, 0.5),
            (.peaking, 570, 1.6, 0.6),
            (.peaking, 1_700, -1.9, 1.3),
            (.peaking, 3_100, 3.3, 1.7),
            (.peaking, 7_100, -6, 1.0),
            (.peaking, 9_400, 9, 2.5),
            (.peaking, 11_940, -12, 4.5),
        ].map { type, hz, gain, q in
            var band = EQBand.makeBand(frequencyHz: hz, filterType: type, gainDB: gain, q: q)
            band.enabled = true
            return band
        }
    }()

    private let grid: [Double] = (0..<200).map { 20 * pow(1_000, Double($0) / 199) }

    private func maxDifference(_ bands: [EQBand], designedAt rate: Double, matched: Bool) -> Double {
        let run = matched ? ReferenceRateDesign.designed(bands, sampleRate: rate) : bands
        return grid.map { hz in
            abs(
                PEQHeadroom.cascadeMagnitudeDB(bands: run, atHz: hz, sampleRate: rate)
                    - PEQHeadroom.cascadeMagnitudeDB(bands: bands, atHz: hz, sampleRate: 44_100)
            )
        }.max() ?? 0
    }

    func testBunnyAtHighRatesMatchesTheCurveTunedAt441() {
        for rate in [48_000.0, 88_200, 96_000, 176_400, 192_000] {
            XCTAssertLessThan(maxDifference(bunny, designedAt: rate, matched: true), 0.65, "rate \(rate)")
        }
        // Without the redesign the 96 kHz curve was off by more than 2 dB.
        XCTAssertGreaterThan(maxDifference(bunny, designedAt: 96_000, matched: false), 2)
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
            XCTAssertEqual(ReferenceRateDesign.designed(bands, sampleRate: rate), bands)
        }
    }

    func testPeakCentreGainAndIdentityAreKept() {
        let bands = bunny
        let designed = ReferenceRateDesign.designed(bands, sampleRate: 96_000)
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
                let designed = ReferenceRateDesign.designed(band, sampleRate: rate)
                XCTAssertTrue(designed.frequencyHz.isFinite && designed.q.isFinite && designed.q > 0)
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
        let designed = ReferenceRateDesign.designed([off, flat, live], sampleRate: 96_000)
        XCTAssertEqual(designed.map(\.id), [off.id, flat.id, live.id])
        XCTAssertEqual(designed[0], off)
        XCTAssertEqual(designed[1], flat)
        XCTAssertNotEqual(designed[2].q, live.q)
    }

    func testProcessorRunsDesignedBandsWhicheverComesFirst() {
        let a = PEQProcessor()
        a.setState(bands: bunny, outputGainDB: 0, bypass: false)
        a.configure(sampleRate: 96_000, channelCount: 2)
        let b = PEQProcessor()
        b.configure(sampleRate: 96_000, channelCount: 2)
        b.setState(bands: bunny, outputGainDB: 0, bypass: false)
        let expected = ReferenceRateDesign.designed(bunny, sampleRate: 96_000)
        XCTAssertEqual(a.runningBands, expected)
        XCTAssertEqual(b.runningBands, expected)
        a.configure(sampleRate: 44_100, channelCount: 2)
        XCTAssertEqual(a.runningBands, bunny)
    }
}
