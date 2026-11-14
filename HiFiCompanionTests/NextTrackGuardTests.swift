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

    /// Log 2026-11-14 13:18: 96 kHz ALAC track, bandwidth dip → Music switched the same track to
    /// a 48 kHz AAC variant. The track was already matched at 96: hold, even if AppleScript says 48.
    func testStreamingVariantOfTheMatchedTrackIsHeld() {
        XCTAssertEqual(
            NextTrackGuard.decide(candidateRate: 48_000, dacRate: 96_000, playingTrackRate: 48_000, matchedTrackRate: 96_000),
            .holdForNextTrack
        )
        XCTAssertEqual(
            NextTrackGuard.decide(candidateRate: 48_000, dacRate: 96_000, playingTrackRate: nil, matchedTrackRate: 96_000),
            .holdForNextTrack
        )
    }

    /// Not yet matched (late log line after a track change, or mode just turned on): AppleScript decides.
    func testUnmatchedTrackStillUsesAppleScript() {
        XCTAssertEqual(
            NextTrackGuard.decide(candidateRate: 96_000, dacRate: 44_100, playingTrackRate: 96_000, matchedTrackRate: nil),
            .apply
        )
    }

    /// Lock or a failed switch left the DAC off the matched rate: the matched rate applies again.
    func testMatchedRateItselfIsNotHeld() {
        XCTAssertEqual(
            NextTrackGuard.decide(candidateRate: 96_000, dacRate: 48_000, playingTrackRate: nil, matchedTrackRate: 96_000),
            .apply
        )
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

    /// Log 2026-10-31 21:22: held 48 kHz (bogus), DAC 44.1, AppleScript already says 96 → apply now.
    func testNewRateFromAppleScriptAppliesAtOnceEvenIfTheHoldDisagrees() {
        XCTAssertFalse(NextTrackGuard.shouldWaitForAppleScript(heldRate: 48_000, playingTrackRate: 96_000, previousTrackRate: 44_100))
    }

    /// Lock held the DAC at 48 while the previous track was 44.1: a stale 44.1 answer must wait.
    func testStaleAnswerIsJudgedAgainstThePreviousTrackNotTheDac() {
        XCTAssertTrue(NextTrackGuard.shouldWaitForAppleScript(heldRate: 96_000, playingTrackRate: 44_100, previousTrackRate: 44_100))
    }

    func testAnswerEqualToThePreviousRateMayBeStaleSoWait() {
        XCTAssertTrue(NextTrackGuard.shouldWaitForAppleScript(heldRate: 96_000, playingTrackRate: 44_100, previousTrackRate: 44_100))
    }

    func testNothingToWaitForWhenHoldAndAnswerAgreeOrEitherIsMissing() {
        XCTAssertFalse(NextTrackGuard.shouldWaitForAppleScript(heldRate: 96_000, playingTrackRate: 96_000, previousTrackRate: 44_100))
        XCTAssertFalse(NextTrackGuard.shouldWaitForAppleScript(heldRate: nil, playingTrackRate: 44_100, previousTrackRate: 44_100))
        XCTAssertFalse(NextTrackGuard.shouldWaitForAppleScript(heldRate: 96_000, playingTrackRate: nil, previousTrackRate: 44_100))
    }
}
