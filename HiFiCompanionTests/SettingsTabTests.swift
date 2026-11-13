import XCTest
@testable import HiFiCompanion

final class SettingsTabTests: XCTestCase {
    func testAppsTabIsHidden() {
        XCTAssertEqual(SettingsTab.visibleTabs, [.general, .output, .diagnostics])
    }
}
