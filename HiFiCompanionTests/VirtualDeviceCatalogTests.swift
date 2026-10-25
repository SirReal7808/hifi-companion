import XCTest

final class VirtualDeviceCatalogTests: XCTestCase {
    func testRecognizesCommonVirtualLoopbacks() {
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        )
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(uid: "Soundflower2ch_UID", name: "Soundflower (2ch)")
        )
    }

    func testAllowsHardwareDAC() {
        XCTAssertFalse(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "AppleUSBAudioEngine:Topping:DX5 II:serial:1",
                name: "DX5 II"
            )
        )
    }

    func testTreatsCompanionAggregatesAsVirtual() {
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "Aggregate:HiFiCompanionProcessTap",
                name: "HiFiCompanionProcessTap"
            )
        )
        // Name alone (no "aggregate" substring) must still be hidden from the pin list.
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "AABB-CCDD",
                name: "HiFiCompanionProcessTap"
            )
        )
        XCTAssertFalse(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "Aggregate:StudioMix",
                name: "Multi-Output Device (Speakers + Headphones)"
            )
        )
    }
}
