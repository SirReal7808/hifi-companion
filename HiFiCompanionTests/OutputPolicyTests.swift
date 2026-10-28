import XCTest

final class OutputPolicyTests: XCTestCase {
    private let dac = "DX5-II-UID"
    private let speakers = "BuiltInSpeakerDevice"

    func testNoPreferenceNeverSwitches() {
        for moment: OutputPolicy.Moment in [.launch, .userSelected, .devicesAdded([dac])] {
            XCTAssertNil(OutputPolicy.systemOutputToSelect(
                at: moment, preferredUID: nil, availableUIDs: [dac, speakers], systemOutputUID: speakers
            ))
        }
    }

    func testLaunchAndUserPickSwitchToPresentPreferred() {
        for moment: OutputPolicy.Moment in [.launch, .userSelected] {
            XCTAssertEqual(OutputPolicy.systemOutputToSelect(
                at: moment, preferredUID: dac, availableUIDs: [dac, speakers], systemOutputUID: speakers
            ), dac)
        }
    }

    func testAbsentPreferredFollowsMacOS() {
        XCTAssertNil(OutputPolicy.systemOutputToSelect(
            at: .launch, preferredUID: dac, availableUIDs: [speakers], systemOutputUID: speakers
        ))
    }

    func testAlreadyOnPreferredDoesNothing() {
        XCTAssertNil(OutputPolicy.systemOutputToSelect(
            at: .userSelected, preferredUID: dac, availableUIDs: [dac], systemOutputUID: dac
        ))
    }

    func testReplugReturnsToPreferred() {
        XCTAssertEqual(OutputPolicy.systemOutputToSelect(
            at: .devicesAdded([dac]), preferredUID: dac, availableUIDs: [dac, speakers], systemOutputUID: speakers
        ), dac)
    }

    func testOtherDeviceAddedRespectsManualMacOSChoice() {
        // Preferred DAC is present but the user moved macOS to the speakers by hand;
        // an unrelated device appearing must not yank the output back.
        XCTAssertNil(OutputPolicy.systemOutputToSelect(
            at: .devicesAdded(["SomeHeadset"]), preferredUID: dac,
            availableUIDs: [dac, speakers, "SomeHeadset"], systemOutputUID: speakers
        ))
    }

    func testTargetSkipsVirtualOutputs() {
        let real = AudioOutputDevice(id: 1, uid: dac, name: "DX5 II")
        let loop = AudioOutputDevice(id: 2, uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        XCTAssertEqual(OutputPolicy.target(systemOutput: real), real)
        XCTAssertNil(OutputPolicy.target(systemOutput: loop))
        XCTAssertNil(OutputPolicy.target(systemOutput: nil))
    }
}
