import AppKit
import XCTest
@testable import HiFiCompanion

final class EQWindowRecoveryTests: XCTestCase {
    func testLostWhenAppKitVisibleButServerOffScreen() {
        XCTAssertTrue(EQWindowRecovery.isLost(appKitVisible: true, miniaturized: false, appHidden: false, serverOnScreen: false))
    }

    func testNotLostWhenOnScreen() {
        XCTAssertFalse(EQWindowRecovery.isLost(appKitVisible: true, miniaturized: false, appHidden: false, serverOnScreen: true))
    }

    func testNotLostWhenClosedMinimizedOrHidden() {
        XCTAssertFalse(EQWindowRecovery.isLost(appKitVisible: false, miniaturized: false, appHidden: false, serverOnScreen: false))
        XCTAssertFalse(EQWindowRecovery.isLost(appKitVisible: true, miniaturized: true, appHidden: false, serverOnScreen: false))
        XCTAssertFalse(EQWindowRecovery.isLost(appKitVisible: true, miniaturized: false, appHidden: true, serverOnScreen: false))
    }

    /// An all-Spaces window was dropped from every Space (2026-11-15); keep it a one-Space window.
    @MainActor
    func testWindowDoesNotJoinAllSpaces() {
        let behavior = PEQPanelController.collectionBehavior
        XCTAssertFalse(behavior.contains(.canJoinAllSpaces))
        // A moveToActiveSpace window lost the front to Music on a Space swipe (2026-11-23).
        XCTAssertFalse(behavior.contains(.moveToActiveSpace))
        XCTAssertTrue(behavior.contains(.managed))
    }
}
