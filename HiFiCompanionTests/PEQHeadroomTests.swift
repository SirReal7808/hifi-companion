import XCTest

final class PEQHeadroomTests: XCTestCase {
    private let sr = 48_000.0

    func testStackedBoostsForceCeilingDown() {
        var bands = EQBand.defaultTenBands()
        // Two nearby +9 dB peaks → cascade peak boost well above 9.
        if let i1 = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }),
           let i2 = bands.firstIndex(where: { abs($0.frequencyHz - 2_000) < 1 }) {
            bands[i1].gainDB = 9
            bands[i1].enabled = true
            bands[i2].gainDB = 9
            bands[i2].enabled = true
        }
        let result = PEQHeadroom.applyBandChange(bands: bands, outputGainDB: 0, sampleRate: sr)
        XCTAssertGreaterThan(result.peakBoostDB, 9)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: result.peakBoostDB)
        XCTAssertEqual(result.outputGainDB, ceiling, accuracy: 1e-9)
        XCTAssertLessThan(result.outputGainDB, -9)
        XCTAssertFalse(result.clippingWarning)
    }

    func testManualGainAboveCeilingSetsWarning() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 12
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        let result = PEQHeadroom.applyManualOutputGain(
            requested: ceiling + 3,
            bands: bands,
            sampleRate: sr
        )
        XCTAssertEqual(result.outputGainDB, ceiling + 3, accuracy: 1e-9)
        XCTAssertTrue(result.clippingWarning)
    }

    func testRelaunchEquivalentKeepsWarningWhileUnsafe() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        let unsafeGain = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost) + 2
        // Simulate persisted state reload.
        let stillAbove = PEQHeadroom.isAboveSafeCeiling(outputGainDB: unsafeGain, peakBoostDB: boost)
        let storedWarning = true
        let restoredWarning = stillAbove || (storedWarning && stillAbove)
        XCTAssertTrue(restoredWarning)
    }

    func testBypassStillAppliesOutputGain() {
        let peq = PEQProcessor()
        peq.configure(sampleRate: sr, channelCount: 2)
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 9
            bands[i].enabled = true
        }
        peq.setState(bands: bands, outputGainDB: -6, bypass: true)

        var samples = [Float](repeating: 0.5, count: 64)
        samples.withUnsafeMutableBufferPointer { buf in
            peq.processInterleaved(buf.baseAddress!, frames: 32, channels: 2)
        }
        let expected = Float(0.5 * pow(10.0, -6.0 / 20.0))
        XCTAssertEqual(samples[0], expected, accuracy: 1e-5)
        // With bypass, band boost must not further change level beyond output gain.
        XCTAssertEqual(samples[10], expected, accuracy: 1e-5)
    }

    func testBandChangeDoesNotAutoRaiseUserLowerGain() {
        var bands = EQBand.defaultTenBands()
        let userLow: Double = -18
        let result = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: userLow,
            sampleRate: sr
        )
        // Flat bands → ceiling ≈ -0.5; user was lower, must stay lower.
        XCTAssertEqual(result.outputGainDB, userLow, accuracy: 1e-9)
        XCTAssertFalse(result.clippingWarning)
    }
}
