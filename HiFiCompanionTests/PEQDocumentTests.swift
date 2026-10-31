import XCTest

@MainActor
final class PEQDocumentTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var profileURL: URL!
    private var clock = Date(timeIntervalSince1970: 1_000)
    private var changes: [PEQDocument.Change] = []

    override func setUp() async throws {
        suiteName = "PEQDocumentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peq-doc-\(UUID().uuidString).json")
        changes = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: profileURL)
    }

    private func makeDocument() -> PEQDocument {
        let document = PEQDocument(
            defaults: defaults,
            profileStore: EQProfileStore(fileURL: profileURL),
            now: { [unowned self] in self.clock }
        )
        document.onChange = { [unowned self] in self.changes.append($0) }
        return document
    }

    // MARK: - Bands

    func testAddRemovePersistsAndNotifies() throws {
        let document = makeDocument()
        let id = try XCTUnwrap(document.addBand())
        XCTAssertEqual(document.bands.count, 1)
        XCTAssertEqual(changes.last, [.dsp, .status])
        XCTAssertNotNil(defaults.data(forKey: "peqBandsJSON"))

        document.removeBand(id: id)
        XCTAssertTrue(document.bands.isEmpty)
        XCTAssertTrue(document.canUndo)
    }

    func testAddStopsAtTenBands() {
        let document = makeDocument()
        for _ in 0..<EQBand.maxBandCount { XCTAssertNotNil(document.addBand()) }
        XCTAssertNil(document.addBand())
        XCTAssertEqual(document.bands.count, EQBand.maxBandCount)
    }

    func testUndoRedoRestoresBands() throws {
        let document = makeDocument()
        let id = try XCTUnwrap(document.addBand())
        document.updateBand(id: id) { $0.gainDB = 4 }
        document.undo()
        XCTAssertEqual(document.bands.first?.gainDB ?? -1, 0, accuracy: 1e-9)
        document.redo()
        XCTAssertEqual(document.bands.first?.gainDB ?? -1, 4, accuracy: 1e-9)
    }

    func testGraphDragIsOneUndoStepAndPreviewOnlyPushesDSP() throws {
        let document = makeDocument()
        let id = try XCTUnwrap(document.addBand())
        changes = []
        document.previewBandDrag(id: id, frequencyHz: 500, gainDB: 2)
        document.previewBandDrag(id: id, frequencyHz: 600, gainDB: 3)
        XCTAssertEqual(changes, [.dsp, .dsp])
        document.commitBandDrag()
        XCTAssertEqual(changes.last, [.dsp, .status])

        document.undo()
        XCTAssertEqual(document.bands.first?.gainDB ?? -1, 0, accuracy: 1e-9)
        document.undo()
        XCTAssertTrue(document.bands.isEmpty, "drag must be exactly one step after the add")
    }

    // MARK: - Continuous knob edits

    func testContinuousTicksCoalesceIntoOneUndoStep() {
        let document = makeDocument()
        document.setAutoOutputGain(false)
        document.setOutputGainDB(-1, continuous: true)
        clock += 0.3
        document.setOutputGainDB(-2, continuous: true)
        clock += 0.3
        document.setOutputGainDB(-3, continuous: true)

        document.undo()
        XCTAssertEqual(document.outputGainDB, 0, accuracy: 1e-9)
        XCTAssertFalse(document.autoOutputGain, "the Auto toggle is its own earlier step")
    }

    func testContinuousRunEndsAfterWindowOrOnOtherControl() {
        let document = makeDocument()
        document.setAutoOutputGain(false)
        document.setOutputGainDB(-1, continuous: true)
        clock += PEQDocument.continuousEditWindow + 0.1
        document.setOutputGainDB(-2, continuous: true)
        document.setToneLevelDB(-6, continuous: true)

        document.undo()
        XCTAssertEqual(document.toneLevelDB, SweepOscillator.defaultLevelDB, accuracy: 1e-9)
        XCTAssertEqual(document.outputGainDB, -2, accuracy: 1e-9)
        document.undo()
        XCTAssertEqual(document.outputGainDB, -1, accuracy: 1e-9)
    }

    func testTypedValueIsItsOwnUndoStep() {
        let document = makeDocument()
        document.setAutoOutputGain(false)
        document.setOutputGainDB(-1, continuous: true)
        document.setOutputGainDB(-5)
        document.undo()
        XCTAssertEqual(document.outputGainDB, -1, accuracy: 1e-9)
    }

    func testToneLevelChangeNotifiesToneOnly() {
        let document = makeDocument()
        document.setToneLevelDB(-6)
        XCTAssertEqual(changes.last, .toneLevel)
        XCTAssertEqual(document.toneLevelDB, -6, accuracy: 1e-9)
        document.setToneLevelDB(-40)
        XCTAssertEqual(document.toneLevelDB, SweepOscillator.minLevelDB, accuracy: 1e-9)
    }

    // MARK: - Sweep marks

    func testFixPeakIsCutDipIsBoostWithQThree() throws {
        let document = makeDocument()
        XCTAssertNil(document.applySweepPeak(), "no needle yet")
        document.setSweepNeedle(hz: 1_000)

        let peakID = try XCTUnwrap(document.applySweepPeak())
        let peak = try XCTUnwrap(document.bands.first { $0.id == peakID })
        XCTAssertEqual(peak.gainDB, -PEQDocument.sweepMarkGainDB, accuracy: 1e-9)
        XCTAssertEqual(peak.q, 3, accuracy: 1e-9)
        XCTAssertEqual(peak.filterType, .peaking)

        // Within ~4 % of the needle → update the same band, not a new one.
        document.setSweepNeedle(hz: 1_030)
        XCTAssertTrue(document.hasPeakingBandNearNeedle)
        XCTAssertEqual(document.applySweepDip(), peakID)
        XCTAssertEqual(document.bands.count, 1)
        XCTAssertEqual(document.bands[0].gainDB, PEQDocument.sweepMarkGainDB, accuracy: 1e-9)
    }

    func testSweepMarkAtFullBandListOnlyUpdatesExisting() {
        let document = makeDocument()
        for _ in 0..<EQBand.maxBandCount { document.addBand() }
        // Defaults sit at 31.5 Hz…16 kHz octaves; 2.8 kHz is far from all of them.
        document.setSweepNeedle(hz: 2_800)
        XCTAssertFalse(document.hasPeakingBandNearNeedle)
        XCTAssertNil(document.applySweepPeak())
    }

    // MARK: - Headroom

    func testAutoLowersOutputGainImmediatelyForBoost() throws {
        let document = makeDocument()
        XCTAssertTrue(document.autoOutputGain)
        let id = try XCTUnwrap(document.addBand())
        document.updateBand(id: id) { $0.frequencyHz = 1_000; $0.gainDB = 6; $0.q = 1 }
        XCTAssertGreaterThan(document.peakBoostDB, 5.9)
        XCTAssertEqual(document.outputGainDB, document.safeCeilingDB, accuracy: 1e-9)
        XCTAssertFalse(document.clippingWarning)
    }

    func testManualOutputGainClampsAndWarns() {
        let document = makeDocument()
        document.setAutoOutputGain(false)
        document.setOutputGainDB(99)
        XCTAssertEqual(document.outputGainDB, PEQHeadroom.maxOutputGainDB, accuracy: 1e-9)
        XCTAssertTrue(document.clippingWarning)
    }

    // MARK: - Profiles

    func testProfileSaveDirtyLoadDelete() throws {
        let document = makeDocument()
        let id = try XCTUnwrap(document.addBand())
        XCTAssertEqual(document.profileDisplayName, "Untitled")
        XCTAssertTrue(document.saveProfile(named: " Moondrop "))
        XCTAssertEqual(document.profileDisplayName, "Moondrop")
        XCTAssertFalse(document.saveProfile(named: "moondrop"), "collision needs overwrite")

        document.updateBand(id: id) { $0.gainDB = 2 }
        XCTAssertEqual(document.profileDisplayName, "Moondrop*")

        let profileID = try XCTUnwrap(document.profileNames.first?.id)
        XCTAssertTrue(document.loadProfile(id: profileID))
        XCTAssertEqual(document.profileDisplayName, "Moondrop")
        XCTAssertEqual(document.bands.first?.gainDB ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(changes.last, [.toneLevel, .dsp, .status])

        document.deleteProfile(id: profileID)
        XCTAssertTrue(document.profileNames.isEmpty)
        XCTAssertEqual(document.profileDisplayName, "Untitled")
    }

    func testResetClearsBandsAndActiveProfile() {
        let document = makeDocument()
        document.addBand()
        document.saveProfile(named: "A")
        document.resetFlat()
        XCTAssertTrue(document.bands.isEmpty)
        XCTAssertNil(document.activeProfileName)
        XCTAssertEqual(document.peakBoostDB, 0, accuracy: 1e-9)
    }

    // MARK: - Persistence

    func testStateSurvivesRelaunch() throws {
        let document = makeDocument()
        let id = try XCTUnwrap(document.addBand())
        document.updateBand(id: id) { $0.frequencyHz = 250; $0.gainDB = -3; $0.filterType = .lowShelf }
        document.setToneLevelDB(-9)
        document.setBypass(true)
        document.setSweepNeedle(hz: 4_000)
        document.persist()

        let relaunched = makeDocument()
        XCTAssertEqual(relaunched.bands, document.bands)
        XCTAssertEqual(relaunched.toneLevelDB, -9, accuracy: 1e-9)
        XCTAssertTrue(relaunched.bypass)
        XCTAssertEqual(relaunched.sweepNeedleHz ?? 0, 4_000, accuracy: 1e-9)
        XCTAssertEqual(relaunched.outputGainDB, document.outputGainDB, accuracy: 1e-9)
    }

    func testLegacyTenFlatBandsMigrateToEmpty() throws {
        let legacy = EQBand.defaultTenBands()
        defaults.set(try JSONEncoder().encode(legacy), forKey: "peqBandsJSON")
        XCTAssertTrue(makeDocument().bands.isEmpty)
    }

    // MARK: - Per-device curves

    func testFirstDeviceAdoptsPre03CurveAndLegacyKeysGo() throws {
        let legacy = makeDocument()
        let id = try XCTUnwrap(legacy.addBand())
        legacy.updateBand(id: id) { $0.gainDB = -4 }

        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        XCTAssertEqual(document.bands.first?.gainDB ?? 0, -4, accuracy: 1e-9)
        XCTAssertNil(defaults.object(forKey: "peqBandsJSON"))
        XCTAssertNotNil(defaults.data(forKey: "peqDeviceCurves"))

        // Only the first device adopts it; the next one starts flat.
        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        XCTAssertTrue(document.bands.isEmpty)
    }

    func testEachDeviceKeepsItsOwnCurve() throws {
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        let dacBand = try XCTUnwrap(document.addBand())
        document.updateBand(id: dacBand) { $0.gainDB = 3 }
        document.saveProfile(named: "Moondrop")

        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        XCTAssertTrue(document.bands.isEmpty)
        XCTAssertNil(document.activeProfileName)
        XCTAssertEqual(changes.last, [.toneLevel, .dsp, .status])
        document.addBand()
        document.addBand()

        document.switchDevice(uid: "DX5", name: "DX5 II")
        XCTAssertEqual(document.bands.count, 1)
        XCTAssertEqual(document.bands[0].gainDB, 3, accuracy: 1e-9)
        XCTAssertEqual(document.activeProfileName, "Moondrop")

        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        XCTAssertEqual(document.bands.count, 2)
    }

    func testSwitchingDeviceClearsUndo() {
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        document.addBand()
        XCTAssertTrue(document.canUndo)
        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        XCTAssertFalse(document.canUndo)
        XCTAssertFalse(document.canRedo)
    }

    func testSameDeviceIsANoOp() {
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        document.addBand()
        changes = []
        document.switchDevice(uid: "DX5", name: "DX5 II")
        XCTAssertTrue(changes.isEmpty)
        XCTAssertTrue(document.canUndo)
    }

    func testDeviceCurvesSurviveRelaunch() throws {
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        let id = try XCTUnwrap(document.addBand())
        document.updateBand(id: id) { $0.frequencyHz = 3_000; $0.gainDB = -2 }
        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")

        let relaunched = makeDocument()
        relaunched.switchDevice(uid: "DX5", name: "DX5 II")
        XCTAssertEqual(relaunched.bands.first?.frequencyHz ?? 0, 3_000, accuracy: 1e-9)
        relaunched.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        XCTAssertTrue(relaunched.bands.isEmpty)
    }

    func testDeviceCurveWithMissingFieldsDecodesWithDefaults() throws {
        let json = #"{"version":1,"devices":{"DX5":{"bands":[{"frequencyHz":250,"gainDB":2}]}}}"#
        defaults.set(Data(json.utf8), forKey: "peqDeviceCurves")
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        let band = try XCTUnwrap(document.bands.first)
        XCTAssertEqual(band.frequencyHz, 250, accuracy: 1e-9)
        XCTAssertEqual(band.filterType, .peaking)
        XCTAssertTrue(band.enabled)
        XCTAssertTrue(document.autoOutputGain)
    }

    func testStoredCurvesListAndForget() throws {
        let document = makeDocument()
        document.switchDevice(uid: "DX5", name: "DX5 II")
        document.addBand()
        document.switchDevice(uid: "Speakers", name: "MacBook Speakers")
        document.addBand()
        document.addBand()

        let listed = document.storedDeviceCurves
        XCTAssertEqual(listed.map(\.uid), ["DX5", "Speakers"])
        XCTAssertEqual(listed.map(\.curve.bands.count), [1, 2])

        // The current device cannot be forgotten.
        document.forgetDeviceCurve(uid: "Speakers")
        XCTAssertEqual(document.storedDeviceCurves.count, 2)

        document.forgetDeviceCurve(uid: "DX5")
        XCTAssertEqual(document.storedDeviceCurves.map(\.uid), ["Speakers"])
        let relaunched = makeDocument()
        relaunched.switchDevice(uid: "DX5", name: "DX5 II")
        XCTAssertTrue(relaunched.bands.isEmpty)
    }
}
