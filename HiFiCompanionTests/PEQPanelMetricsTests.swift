import XCTest
@testable import HiFiCompanion

final class PEQPanelMetricsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        PEQPanelMetrics.activeScreenMaxH = 2_000
        PEQPanelMetrics.measuredSideHeight = 0
    }

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

    func testContentHeightGrowsWhenListExceedsSide() {
        let side = PEQPanelMetrics.sideControlsHeight
        let h4 = PEQPanelMetrics.contentHeightLimits(bandCount: 4, sideHeight: side, screenMaxH: 2_000)
        let listDrivenCount = (0...EQBand.maxBandCount).first { count in
            PEQPanelMetrics.listHeight(bandCount: count) > side + PEQPanelMetrics.sideShadowBleed
        } ?? EQBand.maxBandCount
        let hBefore = PEQPanelMetrics.contentHeightLimits(
            bandCount: max(4, listDrivenCount - 1),
            sideHeight: side,
            screenMaxH: 2_000
        )
        let hList = PEQPanelMetrics.contentHeightLimits(
            bandCount: listDrivenCount,
            sideHeight: side,
            screenMaxH: 2_000
        )
        XCTAssertEqual(hBefore.min, h4.min, accuracy: 0.5)
        XCTAssertGreaterThan(hList.min, hBefore.min)
    }

    func testFourBandFloorAppliesBelowFourBands() {
        let h0 = PEQPanelMetrics.contentHeight(bandCount: 0)
        let h2 = PEQPanelMetrics.contentHeight(bandCount: 2)
        let h4 = PEQPanelMetrics.contentHeight(bandCount: 4)
        XCTAssertEqual(h0, h4, accuracy: 0.5)
        XCTAssertEqual(h2, h4, accuracy: 0.5)
    }

    func testFiveBandHeightIsSideDrivenNotInflated() {
        let layout = PEQPanelMetrics.layout(bandCount: 5, screenMaxH: 2_000)
        let expectedMiddle = PEQPanelMetrics.sideControlsHeight + PEQPanelMetrics.sideShadowBleed
        XCTAssertEqual(layout.middleHeight, expectedMiddle, accuracy: 0.5)
        XCTAssertEqual(layout.graphHeight, PEQPanelMetrics.graphHeightIdeal, accuracy: 0.5)
        XCTAssertLessThan(layout.contentHeight, 850)
    }

    func testMeasuredSideShrinksMiddleAndWindow() {
        let fallback = PEQPanelMetrics.layout(bandCount: 4, screenMaxH: 2_000)
        let measured: CGFloat = 260
        let tight = PEQPanelMetrics.layout(bandCount: 4, screenMaxH: 2_000, sideHeight: measured)
        XCTAssertEqual(
            tight.middleHeight,
            measured + PEQPanelMetrics.sideShadowBleed,
            accuracy: 0.5
        )
        XCTAssertLessThan(tight.contentHeight, fallback.contentHeight - 40)
        // 4-band list (208) stays under measured side — no void padding beyond side+bleed.
        XCTAssertEqual(
            tight.middleHeight,
            max(
                PEQPanelMetrics.listHeight(bandCount: 4),
                measured + PEQPanelMetrics.sideShadowBleed
            ),
            accuracy: 0.5
        )
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

    func testLayoutMatchesContentHeightLimits() {
        for count in [0, 2, 4, 7, 10] {
            let limits = PEQPanelMetrics.contentHeightLimits(bandCount: count, screenMaxH: 2_000)
            let layout = PEQPanelMetrics.layout(bandCount: count, screenMaxH: 2_000)
            XCTAssertEqual(limits.min, layout.contentHeight, accuracy: 0.5, "bandCount=\(count)")
            XCTAssertEqual(
                layout.contentHeight,
                PEQPanelMetrics.chromeExcludingGraph + layout.graphHeight + layout.middleHeight,
                accuracy: 0.5
            )
        }
    }

    func testChromeIsTight() {
        XCTAssertLessThan(PEQPanelMetrics.chromeHeight, 410)
        XCTAssertEqual(PEQPanelMetrics.footerHeight, 30, accuracy: 0.1)
        XCTAssertEqual(PEQPanelMetrics.footerClearance, 0, accuracy: 0.1)
        XCTAssertEqual(PEQPanelMetrics.footerChipInset, 12, accuracy: 0.1)
        XCTAssertEqual(PEQPanelMetrics.sideShadowBleed, 0, accuracy: 0.1)
        // Equal chip insets — no extra strip above Add Band / Reset.
        let chipBlock = PEQPanelMetrics.footerChipInset
            + PEQPanelMetrics.footerHeight
            + PEQPanelMetrics.footerChipInset
        XCTAssertEqual(chipBlock, 54, accuracy: 0.1)
    }

    /// Mert-approved compact footer (`eq-footer-compact-v4` / ver 19) — do not regress.
    func testCompactFooterInvariant() {
        // No strip / no reserved bleed that inflates middle under the glass.
        XCTAssertEqual(PEQPanelMetrics.footerClearance, 0, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.sideShadowBleed, 0, accuracy: 0.01)
        // Equal pad above and below Add Band / Reset.
        XCTAssertEqual(PEQPanelMetrics.footerChipInset, 12, accuracy: 0.01)
        let above = PEQPanelMetrics.footerChipInset
        let below = PEQPanelMetrics.footerChipInset
        XCTAssertEqual(above, below, accuracy: 0.01)
        // Chrome counts exactly one chip inset on each side of the chip row.
        let chipBlock = above + PEQPanelMetrics.footerHeight + below
        XCTAssertEqual(
            PEQPanelMetrics.chromeExcludingGraph,
            2 + 58 + chipBlock + 24,
            accuracy: 0.5
        )
        // Middle hugs the taller column only — no void padding beyond side/list.
        let side: CGFloat = 300
        let layout = PEQPanelMetrics.layout(bandCount: 4, screenMaxH: 2_000, sideHeight: side)
        XCTAssertEqual(layout.middleHeight, side, accuracy: 0.5)
        let listDriven = PEQPanelMetrics.layout(bandCount: 10, screenMaxH: 2_000, sideHeight: side)
        XCTAssertEqual(
            listDriven.middleHeight,
            PEQPanelMetrics.listHeight(bandCount: 10),
            accuracy: 0.5
        )
    }

    /// Glass styling (2026-10-31): 790 pt wide; 52 pt rows in one grouped container, no gaps.
    /// `PEQView.bandRow` uses `.frame(height: PEQPanelMetrics.rowHeight)`.
    func testGlassStylingMetrics() {
        XCTAssertEqual(PEQPanelMetrics.contentWidth, 790, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.rowHeight, 52, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.rowSpacing, 0, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.listVerticalPadding, 0, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.listHeight(bandCount: 4), 208, accuracy: 0.01)
        XCTAssertEqual(PEQPanelMetrics.listHeight(bandCount: 10), 520, accuracy: 0.01)
        // The fallback must not be shorter than the real side glass (337 pt measured).
        XCTAssertGreaterThanOrEqual(PEQPanelMetrics.sideControlsHeight, 337)
    }

    func testMiddleHugsSideWithoutBleedInflation() {
        let middle = PEQPanelMetrics.idealMiddleHeight(bandCount: 4)
        XCTAssertEqual(middle, PEQPanelMetrics.sideControlsHeight, accuracy: 0.5)
        // list(6)=312 < side 340; list(10)=520 exceeds it.
        let m6 = PEQPanelMetrics.idealMiddleHeight(bandCount: 6)
        XCTAssertEqual(m6, PEQPanelMetrics.sideControlsHeight, accuracy: 0.5)
        let m10 = PEQPanelMetrics.idealMiddleHeight(bandCount: 10)
        XCTAssertEqual(m10, PEQPanelMetrics.listHeight(bandCount: 10), accuracy: 0.5)
    }

    func testLaptopVisibleFrameShrinksGraphBeforeClippingFooter() {
        // Typical 14" MacBook visibleFrame height ~845 after menu/Dock → usable ~829.
        let laptop: CGFloat = 820
        let layout = PEQPanelMetrics.layout(bandCount: 4, screenMaxH: laptop)
        XCTAssertLessThanOrEqual(layout.contentHeight, laptop + 0.5)
        XCTAssertGreaterThanOrEqual(layout.graphHeight, PEQPanelMetrics.graphHeightMin - 0.5)
        // Side glass stays fully visible (middle ≥ side+bleed).
        XCTAssertGreaterThanOrEqual(
            layout.middleHeight,
            PEQPanelMetrics.sideControlsHeight + PEQPanelMetrics.sideShadowBleed - 0.5
        )
    }

    func testUsableHeightSubtractsEdgeMargin() {
        // Without a real NSScreen, usableHeight falls back to 900 - margin.
        let h = PEQPanelMetrics.usableHeight(on: nil)
        XCTAssertEqual(h, 900 - PEQPanelMetrics.screenEdgeMargin, accuracy: 0.5)
    }

    func testTenBandHeightStaysWellBelowScreenCap() {
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            screenMaxH: 1_400
        )
        XCTAssertEqual(limits.min, limits.max)
        XCTAssertLessThan(limits.min, 1_000, "10-band H(N) must not approach screen cap")
        let middle = PEQPanelMetrics.idealMiddleHeight(bandCount: 10)
        XCTAssertEqual(middle, PEQPanelMetrics.listHeight(bandCount: 10), accuracy: 0.5)
    }

    func testEffectiveSideHeightPrefersLiveMeasure() {
        PEQPanelMetrics.measuredSideHeight = 312
        XCTAssertEqual(PEQPanelMetrics.effectiveSideHeight, 312, accuracy: 0.5)
        let layout = PEQPanelMetrics.layout(bandCount: 4, screenMaxH: 2_000)
        XCTAssertEqual(layout.middleHeight, 312 + PEQPanelMetrics.sideShadowBleed, accuracy: 0.5)
        PEQPanelMetrics.measuredSideHeight = 0
        XCTAssertEqual(PEQPanelMetrics.effectiveSideHeight, PEQPanelMetrics.sideControlsHeight, accuracy: 0.5)
    }
}
