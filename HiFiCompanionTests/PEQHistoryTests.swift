import XCTest

final class PEQHistoryTests: XCTestCase {
    func testUndoRedoRoundTrip() {
        let history = PEQHistory()
        let a = PEQDocumentSnapshot(
            bands: [],
            outputGainDB: 0,
            autoOutputGain: true,
            bypassGainMatch: true,
            toneLevelDB: -12,
            activeProfileName: nil,
            profileDirty: false
        )
        let b = PEQDocumentSnapshot(
            bands: [EQBand.makeBand(frequencyHz: 1_000, gainDB: 3)],
            outputGainDB: -3,
            autoOutputGain: false,
            bypassGainMatch: true,
            toneLevelDB: -12,
            activeProfileName: "Test",
            profileDirty: true
        )
        XCTAssertFalse(history.canUndo)
        history.push(a)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)

        let restored = history.popUndo(current: b)
        XCTAssertEqual(restored, a)
        XCTAssertTrue(history.canRedo)
        XCTAssertFalse(history.canUndo)

        let redone = history.popRedo(current: a)
        XCTAssertEqual(redone, b)
        XCTAssertTrue(history.canUndo)
        XCTAssertFalse(history.canRedo)
    }

    func testPushClearsRedo() {
        let history = PEQHistory()
        let a = PEQDocumentSnapshot(
            bands: [], outputGainDB: 0, autoOutputGain: true, bypassGainMatch: true,
            toneLevelDB: -12, activeProfileName: nil, profileDirty: false
        )
        let b = PEQDocumentSnapshot(
            bands: [], outputGainDB: -1, autoOutputGain: true, bypassGainMatch: true,
            toneLevelDB: -12, activeProfileName: nil, profileDirty: false
        )
        let c = PEQDocumentSnapshot(
            bands: [], outputGainDB: -2, autoOutputGain: true, bypassGainMatch: true,
            toneLevelDB: -12, activeProfileName: nil, profileDirty: false
        )
        history.push(a)
        _ = history.popUndo(current: b)
        XCTAssertTrue(history.canRedo)
        history.push(c)
        XCTAssertFalse(history.canRedo)
        XCTAssertTrue(history.canUndo)
    }
}
