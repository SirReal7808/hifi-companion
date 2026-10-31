import XCTest

final class NextTrackGuardTests: XCTestCase {
    private let f441 = AudioFormatInfo(sampleRate: 44_100, bitDepth: 24)
    private let f96 = AudioFormatInfo(sampleRate: 96_000, bitDepth: 24)

    /// The log case: "Time Travellers" (44.1) playing, Music logs the next track's 96 kHz at 379 s.
    func testNextTrackPreloadIsHeld() {
        XCTAssertEqual(NextTrackGuard.decide(candidateRate: 96_000, dacRate: 44_100, playingTrackRate: 44_100), .holdForNextTrack)
    }

    func testRateOfThePlayingTrackAppliesNow() {
        XCTAssertEqual(NextTrackGuard.decide(candidateRate: 96_000, dacRate: 44_100, playingTrackRate: 96_000), .apply)
    }

    func testNoRateChangeOrNoAppleScriptKeepsOldBehavior() {
        XCTAssertEqual(NextTrackGuard.decide(candidateRate: 44_100, dacRate: 44_100, playingTrackRate: 96_000), .apply)
        XCTAssertEqual(NextTrackGuard.decide(candidateRate: 96_000, dacRate: nil, playingTrackRate: 44_100), .apply)
        XCTAssertEqual(NextTrackGuard.decide(candidateRate: 96_000, dacRate: 44_100, playingTrackRate: nil), .apply)
    }

    func testHeldFormatAppliesWhenTheNewTrackHasItsRate() {
        let held = AudioFormatInfo(sampleRate: 96_000, bitDepth: 24)
        XCTAssertEqual(NextTrackGuard.formatAtTrackChange(held: held, playingTrackRate: 96_000, dacFormat: f441), held)
    }

    /// The other log case: a 96 kHz track started with no log line (it came 20 s later).
    func testNewTrackRateWithoutAHeldDetectionStillSwitches() {
        XCTAssertEqual(NextTrackGuard.formatAtTrackChange(held: nil, playingTrackRate: 96_000, dacFormat: f441), f96)
    }

    func testSameRateTrackChangeIsNothingToDo() {
        XCTAssertNil(NextTrackGuard.formatAtTrackChange(held: nil, playingTrackRate: 44_100, dacFormat: f441))
    }

    func testSkippedHeldTrackFallsBackToThePlayingRate() {
        // Held 96 for the next track, but the user skipped to a 48 kHz one.
        let result = NextTrackGuard.formatAtTrackChange(held: f96, playingTrackRate: 48_000, dacFormat: f441)
        XCTAssertEqual(result, AudioFormatInfo(sampleRate: 48_000, bitDepth: 24))
    }

    func testWithoutAppleScriptTheHeldFormatIsUsed() {
        XCTAssertEqual(NextTrackGuard.formatAtTrackChange(held: f96, playingTrackRate: nil, dacFormat: f441), f96)
        XCTAssertNil(NextTrackGuard.formatAtTrackChange(held: nil, playingTrackRate: nil, dacFormat: f441))
    }
}
