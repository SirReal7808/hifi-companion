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
}
