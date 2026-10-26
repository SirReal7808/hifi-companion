import XCTest
@testable import HiFiCompanion

final class PEQPanelMetricsTests: XCTestCase {
    func testContentHeightLimitsMaxAlwaysAtLeastMinForBandCounts0Through10() {
        let screenMax: CGFloat = 2_000
        for count in 0...EQBand.maxBandCount {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                sideHeight: PEQPanelMetrics.sideControlsHeight,
                measuredTight: nil,
                screenMaxH: screenMax
            )
            XCTAssertGreaterThanOrEqual(limits.max, limits.min, "bandCount=\(count)")
            XCTAssertGreaterThanOrEqual(limits.min, 1, "bandCount=\(count)")
        }
    }

    func testContentHeightLimitsSurviveTinyScreen() {
        // Screen shorter than ideal min must still yield max >= min >= 1 (no AppKit collapse).
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: 10,
            sideHeight: PEQPanelMetrics.sideControlsHeight,
            measuredTight: nil,
            screenMaxH: 100
        )
        XCTAssertGreaterThanOrEqual(limits.max, limits.min)
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
        XCTAssertGreaterThanOrEqual(limits.max, limits.min)
    }

    func testDeletingBandsNeverInvertsLimits() {
        let screenMax: CGFloat = 1_400
        var previousMax = CGFloat.greatestFiniteMagnitude
        for count in (0...10).reversed() {
            let limits = PEQPanelMetrics.contentHeightLimits(
                bandCount: count,
                sideHeight: 390,
                measuredTight: nil,
                screenMaxH: screenMax
            )
            XCTAssertGreaterThanOrEqual(limits.max, limits.min, "after delete to \(count)")
            XCTAssertLessThanOrEqual(limits.max, previousMax + 0.5, "max should not grow when deleting")
            previousMax = limits.max
        }
    }

    func testMeasuredTightAboveFormulaIsIgnored() {
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
    }
}
