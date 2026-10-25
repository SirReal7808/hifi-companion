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

    func testInterleavedProcessBoosts1kHz() {
        let eq = PeakingBiquad()
        eq.configure(sampleRate: 48_000, frequency: 1_000, q: 1.41)
        eq.setGainDB(9)
        let frames = 4800
        let channels = 2
        var samples = [Float](repeating: 0, count: frames * channels)
        let twoPiF = 2.0 * Double.pi * 1_000.0 / 48_000.0
        for i in 0..<frames {
            let s = Float(0.1 * sin(twoPiF * Double(i)))
            samples[i * 2] = s
            samples[i * 2 + 1] = s
        }
        samples.withUnsafeMutableBufferPointer { buf in
            eq.processInterleaved(buf.baseAddress!, frames: frames, channels: channels)
        }
        // Skip startup transient; measure RMS of processed 1 kHz.
        var sum: Float = 0
        let start = frames / 2
        for i in start..<frames {
            let s = samples[i * 2]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames - start))
        // Dry would be ~0.0707; +9 dB peaking ≈ 2.8× → ~0.2
        XCTAssertGreaterThan(rms, 0.15)
    }
}
