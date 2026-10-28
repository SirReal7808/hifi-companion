import XCTest

final class EQFormatTests: XCTestCase {
    func testGainDBExactZeroHasNoSign() {
        XCTAssertEqual(EQFormat.gainDB(0, fractionDigits: 1), "0.0 dB")
        XCTAssertEqual(EQFormat.gainDB(-0.0, fractionDigits: 1), "0.0 dB")
        XCTAssertEqual(EQFormat.gainDB(0, fractionDigits: 0), "0 dB")
        XCTAssertEqual(EQFormat.gainDB(0, fractionDigits: 1, includeUnit: false), "0.0")
    }

    func testGainDBRoundsToZeroHasNoSign() {
        XCTAssertEqual(EQFormat.gainDB(-0.04, fractionDigits: 1), "0.0 dB")
        XCTAssertEqual(EQFormat.gainDB(0.04, fractionDigits: 1), "0.0 dB")
        XCTAssertEqual(EQFormat.gainDB(-0.4, fractionDigits: 0), "0 dB")
        XCTAssertEqual(EQFormat.gainDB(0.4, fractionDigits: 0), "0 dB")
    }

    func testGainDBNonZeroKeepsSign() {
        XCTAssertEqual(EQFormat.gainDB(2.0, fractionDigits: 1), "+2.0 dB")
        XCTAssertEqual(EQFormat.gainDB(-3.5, fractionDigits: 1), "-3.5 dB")
        XCTAssertEqual(EQFormat.gainDB(-12, fractionDigits: 0), "-12 dB")
        XCTAssertEqual(EQFormat.gainDB(1, fractionDigits: 0, includeUnit: false), "+1")
    }

    func testFrequencyNearWholeKHzKeepsDecimals() {
        // 1.96 kHz used to collapse to "2 kHz" (±50 Hz rounding).
        XCTAssertEqual(EQFormat.frequency(1_960), "1.96 kHz")
        XCTAssertEqual(EQFormat.frequency(10_040), "10.04 kHz")
        XCTAssertEqual(EQFormat.frequency(5_200), "5.20 kHz")
    }

    func testFrequencyWholeKHzDropsDecimals() {
        XCTAssertEqual(EQFormat.frequency(2_000), "2 kHz")
        XCTAssertEqual(EQFormat.frequency(1_999.9), "2 kHz")
        XCTAssertEqual(EQFormat.frequency(20_000), "20 kHz")
    }

    func testFrequencyBelowOneKHz() {
        XCTAssertEqual(EQFormat.frequency(130), "130 Hz")
        XCTAssertEqual(EQFormat.frequency(31.5), "31.5 Hz")
    }

    func testBandQClampsToDSPFloor() {
        var band = EQBand.makeBand(frequencyHz: 1_000, q: 0)
        XCTAssertEqual(band.q, EQBand.minQ, accuracy: 1e-9)
        XCTAssertEqual(EQBand.minQ, 0.1, accuracy: 1e-9)
        band.q = 0.04
        band.clamp()
        XCTAssertEqual(band.q, 0.1, accuracy: 1e-9)
    }
}
