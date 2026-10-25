import XCTest

final class PeakingBiquadTests: XCTestCase {
    func testZeroGainIsBypassed() {
        let eq = PeakingBiquad()
        eq.configure(sampleRate: 48_000)
        eq.setGainDB(0)
        XCTAssertTrue(eq.isBypassed)

        eq.setGainDB(0.01)
        XCTAssertTrue(eq.isBypassed)

        eq.setGainDB(3)
        XCTAssertFalse(eq.isBypassed)
    }

    func testBoostRaisesMagnitudeNearCenter() {
        let eq = PeakingBiquad()
        eq.configure(sampleRate: 48_000, frequency: 1_000, q: 1.41)
        eq.setGainDB(6)
        let atCenter = eq.magnitudeDB(atHz: 1_000)
        let farAway = eq.magnitudeDB(atHz: 100)
        XCTAssertGreaterThan(atCenter, 4.5)
        XCTAssertLessThan(abs(farAway), 1.5)
    }

    func testCutLowersMagnitudeNearCenter() {
        let eq = PeakingBiquad()
        eq.configure(sampleRate: 48_000, frequency: 1_000, q: 1.41)
        eq.setGainDB(-6)
        let atCenter = eq.magnitudeDB(atHz: 1_000)
        XCTAssertLessThan(atCenter, -4.5)
    }
}
