import CoreAudio
import XCTest

final class OutputDeviceDetailsTests: XCTestCase {
    func testLabels() {
        let details = OutputDeviceDetails(
            transportType: kAudioDeviceTransportTypeUSB,
            supportedSampleRates: [96_000, 44_100, 48_000],
            supportedBitDepths: [32, 16, 24],
            bufferFrames: 512,
            latencyFrames: 88,
            sampleRate: 48_000
        )
        XCTAssertEqual(details.transportLabel, "USB")
        XCTAssertEqual(details.sampleRatesLabel, "44.1, 48, 96 kHz")
        XCTAssertEqual(details.bitDepthsLabel, "16, 24, 32-bit")
        XCTAssertEqual(details.bufferLabel, "512 frames · 10.7 ms")
        XCTAssertEqual(details.outputLatencyLabel, "600 frames · 12.5 ms")
    }

    func testMissingValues() {
        let details = OutputDeviceDetails()
        XCTAssertEqual(details.transportLabel, "Unknown")
        XCTAssertEqual(details.sampleRatesLabel, "—")
        XCTAssertEqual(details.bufferLabel, "—")
        XCTAssertEqual(details.outputLatencyLabel, "—")
        XCTAssertEqual(OutputDeviceDetails(bufferFrames: 256).bufferLabel, "256 frames")
    }

    func testSignalLevel() {
        XCTAssertNil(SignalLevel.dbfs(rms: 0))
        XCTAssertNil(SignalLevel.dbfs(rms: 0.0001))
        XCTAssertEqual(SignalLevel.dbfs(rms: 1) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(SignalLevel.dbfs(rms: 0.5) ?? 0, -6.02, accuracy: 0.01)
        XCTAssertEqual(SignalLevel.fraction(dbfs: nil), 0)
        XCTAssertEqual(SignalLevel.fraction(dbfs: -30), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SignalLevel.fraction(dbfs: 0), 1)
    }
}
