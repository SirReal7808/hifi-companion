import XCTest

final class MenuBarTitleTests: XCTestCase {
    private func compose(_ items: Set<MenuBarTitleItem>, device: String? = "DX5 II", sb: String? = "44.1/24", profile: String? = "Moondrop Chu") -> String {
        MenuBarTitle.compose(items: items, device: device, sampleFormat: sb, profile: profile)
    }

    func testNoItemsShowsPlaceholder() {
        XCTAssertEqual(compose([]), "HiFi Companion")
    }

    func testItemsJoinInFixedOrder() {
        XCTAssertEqual(compose([.profile, .device, .sampleFormat]), "DX5 II · 44.1/24 · Moondrop Chu")
        XCTAssertEqual(compose([.profile, .device]), "DX5 II · Moondrop Chu")
    }

    func testMissingValuesAreSkipped() {
        XCTAssertEqual(compose([.device, .sampleFormat], sb: nil), "DX5 II")
        XCTAssertEqual(compose([.profile], profile: "  "), "HiFi Companion")
        XCTAssertEqual(compose([.device], device: nil), "HiFi Companion")
    }

    func testLongItemsAreTruncated() {
        let title = compose([.device], device: "FiiO K9 Pro ESS USB Audio")
        XCTAssertEqual(title, "FiiO K9 Pro ESS U…")
        XCTAssertEqual(title.count, MenuBarTitle.maxItemLength)
        XCTAssertEqual(MenuBarTitle.truncate("Short"), "Short")
    }

    func testCompactFormat() {
        XCTAssertEqual(MenuBarTitle.compactFormat(AudioFormatInfo(sampleRate: 44_100, bitDepth: 24)), "44.1/24")
        XCTAssertEqual(MenuBarTitle.compactFormat(AudioFormatInfo(sampleRate: 96_000, bitDepth: 32)), "96/32")
    }

    func testExcludedAppListNormalizes() {
        XCTAssertEqual(
            EqualizerExclusions.normalized(["com.zoom.xos", "", "com.zoom.xos", " us.zoom.xos "]),
            ["com.zoom.xos", "us.zoom.xos"]
        )
    }

    func testFirstRunLaunchDecision() {
        XCTAssertEqual(FirstRun.launchDecision(welcomeSeen: false, usedBefore: false, firstLaunchDone: false), .show)
        XCTAssertEqual(FirstRun.launchDecision(welcomeSeen: false, usedBefore: false, firstLaunchDone: true), .none)
        XCTAssertEqual(FirstRun.launchDecision(welcomeSeen: false, usedBefore: true, firstLaunchDone: false), .markSeen)
        XCTAssertEqual(FirstRun.launchDecision(welcomeSeen: true, usedBefore: false, firstLaunchDone: false), .none)
    }
}
