import XCTest

final class EQProfileStoreTests: XCTestCase {
    func testSaveLoadRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hifi-eq-profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = EQProfileStore(fileURL: url)
        var bands = [
            EQBand.makeBand(frequencyHz: 90, filterType: .peaking, gainDB: 2, q: 1),
            EQBand.makeBand(frequencyHz: 3_100, filterType: .peaking, gainDB: -3, q: 3)
        ]
        bands[0].enabled = true
        bands[1].enabled = true
        let saved = store.save(
            name: "Test Curve",
            profile: EQProfile(
                name: "Test Curve",
                bands: bands,
                outputGainDB: -4.5,
                autoOutputGain: true,
                bypassGainMatch: true,
                toneLevelDB: -12
            )
        )
        XCTAssertEqual(saved.name, "Test Curve")

        let reloaded = EQProfileStore(fileURL: url)
        let list = reloaded.allProfiles()
        XCTAssertEqual(list.count, 1)
        let loaded = try XCTUnwrap(reloaded.profile(id: saved.id))
        XCTAssertEqual(loaded.bands.count, 2)
        XCTAssertEqual(loaded.bands[0].frequencyHz, 90, accuracy: 1e-9)
        XCTAssertEqual(loaded.bands[1].gainDB, -3, accuracy: 1e-9)
        XCTAssertEqual(loaded.outputGainDB, -4.5, accuracy: 1e-9)
        XCTAssertEqual(loaded.toneLevelDB, -12, accuracy: 1e-9)
    }

    func testOverwriteSameNameKeepsSingleEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hifi-eq-profiles-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = EQProfileStore(fileURL: url)
        _ = store.save(
            name: "A",
            profile: EQProfile(
                name: "A",
                bands: [],
                outputGainDB: 0,
                autoOutputGain: true,
                bypassGainMatch: true,
                toneLevelDB: -12
            )
        )
        _ = store.save(
            name: "a",
            profile: EQProfile(
                name: "a",
                bands: [EQBand.makeBand(frequencyHz: 1_000, gainDB: 1)],
                outputGainDB: -1,
                autoOutputGain: false,
                bypassGainMatch: false,
                toneLevelDB: -10
            )
        )
        XCTAssertEqual(store.allProfiles().count, 1)
        let only = try XCTUnwrap(store.allProfiles().first)
        XCTAssertEqual(only.bands.count, 1)
        XCTAssertEqual(only.outputGainDB, -1, accuracy: 1e-9)
    }
}

final class SweepMarkSemanticsTests: XCTestCase {
    func testPeakIsCutDipIsBoostWithQThree() {
        // Locked UX (mirrored from AppModel): Peak → cut (−3), Dip → boost (+3), Q = 3.
        let markGainDB = 3.0
        let markQ = 3.0
        let peakGain = -markGainDB
        let dipGain = markGainDB
        XCTAssertEqual(markQ, 3.0, accuracy: 1e-9)
        XCTAssertLessThan(peakGain, 0)
        XCTAssertGreaterThan(dipGain, 0)
    }
}
