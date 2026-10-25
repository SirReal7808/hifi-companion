import XCTest

final class SweepOscillatorTests: XCTestCase {
    func testDefaultLevelIsMinusTwelve() {
        XCTAssertEqual(SweepOscillator.defaultLevelDB, -12, accuracy: 1e-9)
        XCTAssertEqual(SweepOscillator.linearGain(forDB: -12), pow(10.0, -12.0 / 20.0), accuracy: 1e-12)
    }

    func testLevelClamp() {
        XCTAssertEqual(SweepOscillator.clampLevelDB(-30), -20, accuracy: 1e-9)
        XCTAssertEqual(SweepOscillator.clampLevelDB(3), 0, accuracy: 1e-9)
        XCTAssertEqual(SweepOscillator.clampLevelDB(-12), -12, accuracy: 1e-9)
    }

    func testFrequencyUpdateDoesNotResetPhaseContinuity() {
        let osc = SweepOscillator()
        osc.configure(sampleRate: 48_000)
        osc.setLevelDB(-6)
        osc.press(atHz: 440)
        var a = [Float](repeating: 0, count: 256)
        a.withUnsafeMutableBufferPointer { osc.renderMono($0.baseAddress!, frames: 256) }
        let midPhaseSample = a[200]
        // Glide to a nearby frequency without release — should stay continuous (no zero restart).
        osc.updateFrequency(atHz: 480)
        var b = [Float](repeating: 0, count: 64)
        b.withUnsafeMutableBufferPointer { osc.renderMono($0.baseAddress!, frames: 64) }
        // First sample after update should not jump to silence.
        XCTAssertGreaterThan(abs(b[0]), 1e-4)
        XCTAssertGreaterThan(abs(midPhaseSample), 1e-4)
    }

    func testReleaseFadesTowardSilence() {
        let osc = SweepOscillator()
        osc.configure(sampleRate: 48_000)
        osc.setLevelDB(0)
        osc.press(atHz: 1_000)
        var warm = [Float](repeating: 0, count: 2_048)
        warm.withUnsafeMutableBufferPointer { osc.renderMono($0.baseAddress!, frames: 2_048) }
        XCTAssertTrue(osc.isAudible)
        osc.release()
        var fade = [Float](repeating: 0, count: 8_192)
        fade.withUnsafeMutableBufferPointer { osc.renderMono($0.baseAddress!, frames: 8_192) }
        let tail = abs(fade[fade.count - 1])
        XCTAssertLessThan(tail, 0.02)
    }

    func testPressProducesEnergyNearToneLevel() {
        let osc = SweepOscillator()
        osc.configure(sampleRate: 48_000)
        osc.setLevelDB(-12)
        osc.press(atHz: 1_000)
        var buf = [Float](repeating: 0, count: 4_800)
        buf.withUnsafeMutableBufferPointer { osc.renderMono($0.baseAddress!, frames: 4_800) }
        var sum: Float = 0
        let start = 2_000
        for i in start..<buf.count {
            sum += buf[i] * buf[i]
        }
        let rms = sqrt(sum / Float(buf.count - start))
        let expected = Float(SweepOscillator.linearGain(forDB: -12) / sqrt(2.0))
        XCTAssertEqual(rms, expected, accuracy: expected * 0.25)
    }
}
