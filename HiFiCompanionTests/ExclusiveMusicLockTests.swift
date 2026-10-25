import XCTest

final class ExclusiveMusicLockTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 2_000_000)

    func testShortChirpDoesNotLockBeforeGrace() {
        var lock = ExclusiveMusicLock(lockGrace: 0.85, unlockGrace: 0.6)

        XCTAssertEqual(lock.update(competingAudible: true, now: t0), .unchanged)
        XCTAssertFalse(lock.isLocked)

        XCTAssertEqual(
            lock.update(competingAudible: true, now: t0.addingTimeInterval(0.4)),
            .unchanged
        )
        XCTAssertFalse(lock.isLocked)

        // Chirp ends before grace → never locks.
        XCTAssertEqual(
            lock.update(competingAudible: false, now: t0.addingTimeInterval(0.5)),
            .unchanged
        )
        XCTAssertFalse(lock.isLocked)
    }

    func testPersistentCompetitorLocksAfterGrace() {
        var lock = ExclusiveMusicLock(lockGrace: 0.85, unlockGrace: 0.6)

        _ = lock.update(competingAudible: true, now: t0)
        XCTAssertEqual(
            lock.update(competingAudible: true, now: t0.addingTimeInterval(0.9)),
            .locked
        )
        XCTAssertTrue(lock.isLocked)
    }

    func testUnlockAfterCompetitorStopsPastUnlockGrace() {
        var lock = ExclusiveMusicLock(lockGrace: 0.85, unlockGrace: 0.6)

        _ = lock.update(competingAudible: true, now: t0)
        _ = lock.update(competingAudible: true, now: t0.addingTimeInterval(1.0))
        XCTAssertTrue(lock.isLocked)

        XCTAssertEqual(
            lock.update(competingAudible: false, now: t0.addingTimeInterval(1.1)),
            .unchanged
        )
        XCTAssertTrue(lock.isLocked)

        XCTAssertEqual(
            lock.update(competingAudible: false, now: t0.addingTimeInterval(1.8)),
            .unlocked
        )
        XCTAssertFalse(lock.isLocked)
    }

    func testIgnoredSystemBundlesListed() {
        XCTAssertTrue(
            DeviceAudioClientProbe.ignoredSystemBundleIDs.contains("com.apple.controlcenter")
        )
        XCTAssertTrue(DeviceAudioClientProbe.musicBundleIDs.contains("com.apple.Music"))
        XCTAssertTrue(DeviceAudioClientProbe.selfBundleIDs.contains("com.hificompanion.app"))
    }
}
