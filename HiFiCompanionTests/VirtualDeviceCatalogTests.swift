import XCTest

final class VirtualDeviceCatalogTests: XCTestCase {
    func testRecognizesBlackHoleUID() {
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        )
        XCTAssertTrue(
            VirtualDeviceCatalog.isPreferredVirtual(uid: "BlackHole2ch_UID", name: "BlackHole 2ch")
        )
    }

    func testIgnoresHardwareDAC() {
        XCTAssertFalse(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "AppleUSBAudioEngine:Topping:DX5 II:1",
                name: "DX5 II"
            )
        )
    }

    func testTreatsBlackHoleAggregatesAsVirtual() {
        XCTAssertTrue(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "Aggregate:BlackHoleBridge",
                name: "Multi-Output Device (BlackHole)"
            )
        )
        XCTAssertFalse(
            VirtualDeviceCatalog.isVirtualLoopback(
                uid: "Aggregate:SpeakersOnly",
                name: "Multi-Output Device"
            )
        )
    }
}
