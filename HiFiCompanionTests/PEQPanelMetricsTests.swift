import XCTest
@testable import HiFiCompanion

final class PEQPanelMetricsTests: XCTestCase {
    func testContentHeightLimitsAreFixedMinEqualsMaxForAllBandCounts() {
        let screenMax: CGFloat = 2_000
        for count in 0...EQBand.maxBandCount {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                screenMaxH: screenMax
            )
            XCTAssertEqual(limits.max, limits.min, accuracy: 0.01, "bandCount=\(count) must be fixed height")
            XCTAssertGreaterThanOrEqual(limits.min, 1, "bandCount=\(count)")
        }
    }

    func testContentHeightGrowsWithBandCountAboveFloor() {
        let h4 = PEQPanelMetrics.contentHeightLimits(bandCount: 4, screenMaxH: 2_000)
        let h8 = PEQPanelMetrics.contentHeightLimits(bandCount: 8, screenMaxH: 2_000)
        let h9 = PEQPanelMetrics.contentHeightLimits(bandCount: 9, screenMaxH: 2_000)
        let h10 = PEQPanelMetrics.contentHeightLimits(bandCount: 10, screenMaxH: 2_000)
        XCTAssertEqual(h4.min, h4.max)
        XCTAssertEqual(h8.min, h8.max)
        // Through 8 bands, middle stays side+shadowBleed (390); list(8)=380 still under.
        XCTAssertEqual(h8.min, h4.min, accuracy: 0.5)
        // 9 bands: list 428 > 390 → grows.
        XCTAssertGreaterThan(h9.min, h4.min)
        XCTAssertGreaterThan(h10.min, h9.min)
    }

    func testFourBandFloorAppliesBelowFourBands() {
        let h0 = PEQPanelMetrics.contentHeight(bandCount: 0)
        let h2 = PEQPanelMetrics.contentHeight(bandCount: 2)
        let h4 = PEQPanelMetrics.contentHeight(bandCount: 4)
        XCTAssertEqual(h0, h4, accuracy: 0.5)
        XCTAssertEqual(h2, h4, accuracy: 0.5)
    }

    func testFiveBandHeightIsSideDrivenNotInflated() {
        // Regression: PreferenceKey side probes used to push H(5) toward screen×0.85.
        let h5 = PEQPanelMetrics.contentHeight(bandCount: 5)
        let expected = PEQPanelMetrics.chromeHeight
            + PEQPanelMetrics.sideControlsHeight
            + PEQPanelMetrics.sideShadowBleed
        // list(5)=236 < side+bleed → middle == side+shadow room.
        XCTAssertEqual(h5, expected, accuracy: 0.5)
        XCTAssertLessThan(h5, 850)
    }

    func testContentHeightLimitsSurviveTinyScreen() {
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            screenMaxH: 100
        )
        XCTAssertEqual(limits.min, limits.max)
        XCTAssertGreaterThanOrEqual(limits.min, 1)
    }

    func testDeletingBandsNeverInvertsOrOpensResizeRange() {
        let screenMax: CGFloat = 1_400
        var previousMax = CGFloat.greatestFiniteMagnitude
        for count in (0...10).reversed() {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                screenMaxH: screenMax
            )
            XCTAssertEqual(limits.max, limits.min, accuracy: 0.01, "after delete to \(count)")
            XCTAssertLessThanOrEqual(limits.max, previousMax + 0.5, "height should not grow when deleting")
            previousMax = limits.max
        }
    }

    func testMiddleRegionHeightMatchesFixedContentMinusChrome() {
        for count in [0, 2, 4, 7, 10] {
            let limits = PEQPanelMetrics.contentHeightLimits(bandCount: count, screenMaxH: 2_000)
            let middle = PEQPanelMetrics.middleRegionHeight(bandCount: count)
            XCTAssertEqual(limits.min, PEQPanelMetrics.chromeHeight + middle, accuracy: 0.5, "bandCount=\(count)")
        }
    }

    func testChromeIsTight() {
        XCTAssertLessThan(PEQPanelMetrics.chromeHeight, 430)
        XCTAssertEqual(PEQPanelMetrics.footerHeight, 47, accuracy: 0.1)
        XCTAssertEqual(PEQPanelMetrics.footerClearance, 28, accuracy: 0.1)
        XCTAssertEqual(PEQPanelMetrics.footerChipInset, 8, accuracy: 0.1)
    }

    func testMiddleIncludesSideShadowBleed() {
        // N≤7: middle tracks side+shadow so Peak/Dip shadow never sits in the footer.
        let middle = PEQPanelMetrics.middleRegionHeight(bandCount: 4)
        XCTAssertEqual(
            middle,
            PEQPanelMetrics.sideControlsHeight + PEQPanelMetrics.sideShadowBleed,
            accuracy: 0.5
        )
        // N=8 list 380 < side+bleed 390 → still shadow-sized.
        let m8 = PEQPanelMetrics.middleRegionHeight(bandCount: 8)
        XCTAssertEqual(m8, PEQPanelMetrics.sideControlsHeight + PEQPanelMetrics.sideShadowBleed, accuracy: 0.5)
        // N=10 list 476 > side+bleed → list wins.
        let m10 = PEQPanelMetrics.middleRegionHeight(bandCount: 10)
        XCTAssertEqual(m10, PEQPanelMetrics.listHeight(bandCount: 10), accuracy: 0.5)
    }

    func testTenBandHeightStaysWellBelowScreenCap() {
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            screenMaxH: 1_400
        )
        XCTAssertEqual(limits.min, limits.max)
        XCTAssertLessThan(limits.min, 1_000, "10-band H(N) must not approach screen cap")
        let middle = PEQPanelMetrics.middleRegionHeight(bandCount: 10)
        XCTAssertEqual(middle, PEQPanelMetrics.listHeight(bandCount: 10), accuracy: 0.5)
    }
}
