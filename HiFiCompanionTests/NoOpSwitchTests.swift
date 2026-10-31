import CoreAudio
import XCTest

/// A track whose DAC format is already in place must not stop and rebuild the tap
/// (it used to, mid-track, when a second detection reported a different bit depth).
final class NoOpSwitchTests: XCTestCase {
    private let dac441x24 = AudioFormatInfo(sampleRate: 44_100, bitDepth: 24)

    private func noOp(
        planned: AudioFormatInfo?,
        current: AudioFormatInfo?,
        equalizer: Bool = true,
        tapOnDevice: Bool = true,
        tapRate: Double = 44_100
    ) -> Bool {
        PhysicalFormatChooser.isNoOpSwitch(
            planned: planned,
            current: current,
            equalizerEnabled: equalizer,
            tapRunningOnDevice: tapOnDevice,
            tapSampleRate: tapRate
        )
    }

    func testSameFormatWithTapRunningThereIsANoOp() {
        XCTAssertTrue(noOp(planned: dac441x24, current: dac441x24))
    }

    func testSameFormatWithEqualizerOffIsANoOp() {
        XCTAssertTrue(noOp(planned: dac441x24, current: dac441x24, equalizer: false, tapOnDevice: false, tapRate: 0))
    }

    func testRateOrBitDepthChangeIsNotANoOp() {
        XCTAssertFalse(noOp(planned: AudioFormatInfo(sampleRate: 96_000, bitDepth: 24), current: dac441x24))
        XCTAssertFalse(noOp(planned: AudioFormatInfo(sampleRate: 44_100, bitDepth: 32), current: dac441x24))
    }

    func testTapMissingOrOnAnotherRateStillRebuilds() {
        // e.g. output just changed: the tap has to move even though the format matches.
        XCTAssertFalse(noOp(planned: dac441x24, current: dac441x24, tapOnDevice: false))
        XCTAssertFalse(noOp(planned: dac441x24, current: dac441x24, tapRate: 48_000))
    }

    func testRateWithinOneHertzCountsAsTheSame() {
        XCTAssertTrue(noOp(planned: AudioFormatInfo(sampleRate: 44_100.4, bitDepth: 24), current: dac441x24))
    }

    func testUnknownFormatsAreNeverANoOp() {
        XCTAssertFalse(noOp(planned: nil, current: dac441x24))
        XCTAssertFalse(noOp(planned: dac441x24, current: nil))
    }

    /// The case from the log (2026-10-31 18:56:57): ALAC said 16-bit, AudioQueue 24-bit; both
    /// choose the DAC's 24-bit container at 44.1 kHz.
    func testSixteenAndTwentyFourBitReportsLandOnTheSameContainer() {
        let available = [16, 24, 32].map { bits -> AudioStreamBasicDescription in
            var d = AudioStreamBasicDescription()
            d.mSampleRate = 44_100
            d.mBitsPerChannel = UInt32(bits)
            return d
        }
        let withoutSixteen = available.filter { $0.mBitsPerChannel != 16 }
        let from16 = PhysicalFormatChooser.choose(requested: AudioFormatInfo(sampleRate: 44_100, bitDepth: 16), available: withoutSixteen)
        let from24 = PhysicalFormatChooser.choose(requested: AudioFormatInfo(sampleRate: 44_100, bitDepth: 24), available: withoutSixteen)
        XCTAssertEqual(from16?.mBitsPerChannel, 24)
        XCTAssertEqual(from24?.mBitsPerChannel, 24)
    }
}
