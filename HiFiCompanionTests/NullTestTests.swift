import XCTest

final class NullTestTests: XCTestCase {
    private let channels = 2

    private func reference(frames: Int = 4_000, leadIn: Int = 100) -> [Float] {
        NullTest.float(fromInt24: NullTest.referenceInt24(frames: frames, channels: channels, leadInFrames: leadIn))
    }

    /// Capture = some silence, then the reference (with its own lead-in), then silence.
    private func capture(_ ref: [Float], delayFrames: Int, tailFrames: Int = 300) -> [Float] {
        [Float](repeating: 0, count: delayFrames * channels) + ref + [Float](repeating: 0, count: tailFrames * channels)
    }

    func testReferenceIsDeterministicSoftAndSilentFirst() {
        let a = NullTest.referenceInt24(frames: 1_000, channels: 2, leadInFrames: 50)
        XCTAssertEqual(a, NullTest.referenceInt24(frames: 1_000, channels: 2, leadInFrames: 50))
        XCTAssertTrue(a.prefix(100).allSatisfy { $0 == 0 })
        XCTAssertTrue(a.allSatisfy { abs($0) <= NullTest.noisePeak })
        XCTAssertGreaterThan(Set(a).count, 1_000, "noise, not a constant")
    }

    func testInt24ConvertsExactly() {
        XCTAssertEqual(NullTest.float(fromInt24: [8_388_607, -8_388_608, 1, 0]),
                       [Float(8_388_607) / 8_388_608, -1, 1 / 8_388_608, 0])
    }

    func testIdenticalDelayedCaptureIsBitExact() {
        let ref = reference()
        let result = NullTest.compare(reference: ref, captured: capture(ref, delayFrames: 777), channels: channels)
        XCTAssertTrue(result.isBitExact)
        XCTAssertEqual(result.offsetFrames, 777 + 100)
        XCTAssertEqual(result.comparedSamples, (4_000) * channels)
        XCTAssertEqual(result.nullDepthDB, -.infinity)
    }

    func testOneChangedSampleIsReported() {
        let ref = reference()
        var cap = capture(ref, delayFrames: 10)
        cap[(10 + 2_000) * channels + 1] += 1 / 8_388_608
        let result = NullTest.compare(reference: ref, captured: cap, channels: channels)
        XCTAssertTrue(result.aligned)
        XCTAssertFalse(result.isBitExact)
        XCTAssertEqual(result.mismatches, 1)
        XCTAssertLessThan(result.nullDepthDB, -100)
    }

    func testCutShortCaptureIsNeverBitExact() {
        let ref = reference()
        let full = capture(ref, delayFrames: 20, tailFrames: 0)
        let cut = Array(full.prefix(full.count - 500 * channels))
        let result = NullTest.compare(reference: ref, captured: cut, channels: channels)
        XCTAssertTrue(result.aligned)
        XCTAssertEqual(result.mismatches, 0)
        XCTAssertLessThan(result.comparedSamples, result.expectedSamples)
        XCTAssertFalse(result.isBitExact)
    }

    func testGainChangeFallsBackToCorrelationAndMeasuresDepth() {
        let ref = reference()
        let gain = Float(0.5) // −6 dB: no exact frame anywhere
        let cap = capture(ref, delayFrames: 50).map { $0 * gain }
        let result = NullTest.compare(reference: ref, captured: cap, channels: channels)
        XCTAssertTrue(result.aligned)
        XCTAssertEqual(result.offsetFrames, 50 + 100)
        XCTAssertFalse(result.isBitExact)
        XCTAssertEqual(result.nullDepthDB, 20 * log10(0.5), accuracy: 0.01) // residual = half the signal
    }

    func testSilentCaptureIsNotFound() {
        let result = NullTest.compare(reference: reference(), captured: [Float](repeating: 0, count: 20_000), channels: channels)
        XCTAssertFalse(result.aligned)
        XCTAssertFalse(result.isBitExact)
    }
}
