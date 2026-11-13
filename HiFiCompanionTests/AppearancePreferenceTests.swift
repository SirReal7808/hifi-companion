import AppKit
import XCTest
@testable import HiFiCompanion

final class AppearancePreferenceTests: XCTestCase {
    func testAppearanceNames() {
        XCTAssertNil(AppearancePreference.system.appearanceName)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
    }

    /// The menu bar panel and status item keep the system appearance; app windows follow the setting.
    func testMenuBarWindowsKeepSystemAppearance() {
        XCTAssertFalse(AppearancePreference.followsPreference(windowClassName: "MenuBarExtraWindow"))
        XCTAssertFalse(AppearancePreference.followsPreference(windowClassName: "NSStatusBarWindow"))
        XCTAssertTrue(AppearancePreference.followsPreference(windowClassName: "NSWindow"))
        XCTAssertTrue(AppearancePreference.followsPreference(windowClassName: "ExactHeightEQPanel"))
    }
}
