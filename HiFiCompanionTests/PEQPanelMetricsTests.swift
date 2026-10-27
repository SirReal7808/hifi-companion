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
        let h10 = PEQPanelMetrics.contentHeightLimits(bandCount: 10, screenMaxH: 2_000)
        XCTAssertEqual(h4.min, h4.max)
        XCTAssertEqual(h8.min, h8.max)
        // 8 bands: list 380 > side 372 → taller than 4-band floor.
        XCTAssertGreaterThan(h8.min, h4.min)
        XCTAssertGreaterThan(h10.min, h8.min)
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
        let expected = PEQPanelMetrics.chromeHeight + PEQPanelMetrics.sideControlsHeight
        // list(5)=236 < side 372, and floor list(4)=188 < side → middle == side.
        XCTAssertEqual(h5, expected, accuracy: 0.5)
        XCTAssertLessThan(h5, 800)
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
        XCTAssertLessThan(PEQPanelMetrics.chromeHeight, 370)
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
