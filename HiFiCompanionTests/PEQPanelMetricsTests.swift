import XCTest
@testable import HiFiCompanion

final class PEQPanelMetricsTests: XCTestCase {
    func testContentHeightLimitsAreFixedMinEqualsMaxForAllBandCounts() {
        let screenMax: CGFloat = 2_000
        for count in 0...EQBand.maxBandCount {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                sideHeight: PEQPanelMetrics.sideControlsHeight,
                measuredTight: nil,
                screenMaxH: screenMax
            )
            XCTAssertEqual(limits.max, limits.min, accuracy: 0.01, "bandCount=\(count) must be fixed height")
            XCTAssertGreaterThanOrEqual(limits.min, 1, "bandCount=\(count)")
        }
    }

    func testContentHeightGrowsWithBandCountAboveFloor() {
        let h4 = PEQPanelMetrics.contentHeightLimits(bandCount: 4, screenMaxH: 2_000)
        let h8 = PEQPanelMetrics.contentHeightLimits(bandCount: 8, screenMaxH: 2_000)
        XCTAssertEqual(h4.min, h4.max)
        XCTAssertEqual(h8.min, h8.max)
        XCTAssertGreaterThan(h8.min, h4.min)
    }

    func testContentHeightLimitsSurviveTinyScreen() {
        // Screen shorter than ideal must still yield min == max >= 1 (no AppKit collapse).
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            sideHeight: PEQPanelMetrics.sideControlsHeight,
            measuredTight: nil,
            screenMaxH: 100
        )
        XCTAssertEqual(limits.min, limits.max)
        XCTAssertGreaterThanOrEqual(limits.min, 1)
    }

    func testRunawaySideHeightIsCapped() {
        let runaway: CGFloat = 4_000
        let capped = PEQPanelMetrics.clampedSideHeight(runaway)
        XCTAssertEqual(capped, PEQPanelMetrics.sideControlsHeightCap)

        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 2,
            sideHeight: runaway,
            measuredTight: nil,
            screenMaxH: 2_000
        )
        let sane = PEQPanelMetrics.contentHeightLimits(
            bandCount: 2,
            sideHeight: PEQPanelMetrics.sideControlsHeightCap,
            measuredTight: nil,
            screenMaxH: 2_000
        )
        XCTAssertEqual(limits.min, sane.min)
        XCTAssertEqual(limits.max, sane.max)
        XCTAssertEqual(limits.min, limits.max)
    }

    func testDeletingBandsNeverInvertsOrOpensResizeRange() {
        let screenMax: CGFloat = 1_400
        var previousMax = CGFloat.greatestFiniteMagnitude
        for count in (0...10).reversed() {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                sideHeight: 390,
                measuredTight: nil,
                screenMaxH: screenMax
            )
            XCTAssertEqual(limits.max, limits.min, accuracy: 0.01, "after delete to \(count)")
            XCTAssertLessThanOrEqual(limits.max, previousMax + 0.5, "height should not grow when deleting")
            previousMax = limits.max
        }
    }

    func testMeasuredTightFarAboveFormulaIsIgnored() {
        let formula = PEQPanelMetrics.contentHeightLimits(
            bandCount: 6,
            measuredTight: nil,
            screenMaxH: 2_000
        )
        let runaway = PEQPanelMetrics.contentHeightLimits(
            bandCount: 6,
            measuredTight: formula.max + 200,
            screenMaxH: 2_000
        )
        XCTAssertEqual(runaway.max, formula.max, accuracy: 0.5)
        XCTAssertEqual(runaway.min, runaway.max)
    }

    func testMeasuredTightNearFormulaKeepsFixedHeight() {
        let formula = PEQPanelMetrics.contentHeightLimits(
            bandCount: 5,
            measuredTight: nil,
            screenMaxH: 2_000
        )
        let near = PEQPanelMetrics.contentHeightLimits(
            bandCount: 5,
            measuredTight: formula.max + 8,
            screenMaxH: 2_000
        )
        XCTAssertEqual(near.min, near.max)
        XCTAssertEqual(near.min, formula.max + 8, accuracy: 0.5)
    }

    func testMiddleRegionHeightMatchesFixedContentMinusChrome() {
        for count in [0, 2, 4, 7, 10] {
            let limits = PEQPanelMetrics.contentHeightLimits(bandCount: count, screenMaxH: 2_000)
            let middle = PEQPanelMetrics.middleRegionHeight(bandCount: count)
            XCTAssertEqual(limits.min, PEQPanelMetrics.chromeHeight + middle, accuracy: 0.5, "bandCount=\(count)")
        }
    }

    func testChromeBottomPadIsTight() {
        // Regression: large bottom pad + clearance stacked into a void under Add Band / Reset.
        XCTAssertLessThanOrEqual(PEQPanelMetrics.footerClearance, 10)
        // chromeHeight embeds bottomPad 4 + footer 28; keep total chrome bounded.
        XCTAssertLessThan(PEQPanelMetrics.chromeHeight, 370)
    }

    func testTenBandHeightStaysWellBelowScreenCap() {
        // Regression: open-too-tall void (~screen*0.85) under Add Band / Reset.
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            sideHeight: PEQPanelMetrics.sideControlsHeight,
            measuredTight: nil,
            screenMaxH: 1_400
        )
        XCTAssertEqual(limits.min, limits.max)
        XCTAssertLessThan(limits.min, 1_000, "10-band H(N) must not approach screen cap")
        let middle = PEQPanelMetrics.middleRegionHeight(bandCount: 10)
        XCTAssertEqual(middle, PEQPanelMetrics.listHeight(bandCount: 10), accuracy: 0.5)
    }
}
