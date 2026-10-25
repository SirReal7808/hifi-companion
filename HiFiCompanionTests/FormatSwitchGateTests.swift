import XCTest

final class FormatSwitchGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func detection(
        rate: Double,
        bitDepth: Int = 24,
        source: DetectionSource,
        at offset: TimeInterval
    ) -> FormatDetection {
        FormatDetection(
            format: AudioFormatInfo(sampleRate: rate, bitDepth: bitDepth),
            source: source,
            detectedAt: t0.addingTimeInterval(offset)
        )
    }

    func testDelayedLowerRateDuringSettleAfterUpswitchIsIgnored() {
        var gate = FormatSwitchGate(settleWindow: 3.0)

        let first96 = detection(rate: 96_000, source: .alacInput, at: 0)
        XCTAssertEqual(gate.consider(first96, now: t0), .apply(first96))
        gate.didApply(first96, previouslyApplied: nil, at: t0)

        // Simulate the reported bug: after applying 96, a stale 44.1 log arrives within settle.
        let stale441 = detection(rate: 44_100, bitDepth: 16, source: .audioCapabilities, at: 0.4)
        XCTAssertEqual(gate.consider(stale441, now: t0.addingTimeInterval(0.5)), .ignore)

        let staleQueue = detection(rate: 44_100, source: .audioQueue, at: 0.6)
        XCTAssertEqual(gate.consider(staleQueue, now: t0.addingTimeInterval(0.7)), .ignore)

        // Even ALAC teardown of the previous track must not snap back during settle.
        let staleALAC = detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: 0.8)
        XCTAssertEqual(gate.consider(staleALAC, now: t0.addingTimeInterval(0.9)), .ignore)

        // DAC should still be considered at 96.
        XCTAssertEqual(gate.lastApplied?.format.sampleRate, 96_000)
    }

    func testOlderDetectionThanLastAppliedIsIgnored() {
        var gate = FormatSwitchGate(settleWindow: 3.0)

        let applied96 = detection(rate: 96_000, source: .alacInput, at: 2.0)
        XCTAssertEqual(gate.consider(applied96, now: t0.addingTimeInterval(2.0)), .apply(applied96))
        gate.didApply(applied96, previouslyApplied: nil, at: t0.addingTimeInterval(2.0))

        // Past settle, but detection timestamp is older than the applied 96 line.
        let older441 = detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: 1.0)
        XCTAssertEqual(
            gate.consider(older441, now: t0.addingTimeInterval(6.0)),
            .ignore
        )
    }

    func testLowPriorityCannotOverrideHighPriorityAfterSettle() {
        var gate = FormatSwitchGate(settleWindow: 3.0)

        let applied96 = detection(rate: 96_000, source: .alacInput, at: 0)
        gate.didApply(applied96, previouslyApplied: nil, at: t0)

        let lateCapabilities = detection(rate: 44_100, bitDepth: 16, source: .audioCapabilities, at: 5)
        XCTAssertEqual(
            gate.consider(lateCapabilities, now: t0.addingTimeInterval(5)),
            .ignore
        )
    }

    func testTrackChangeAllowsALACDowngradeDuringSettle() {
        var gate = FormatSwitchGate(settleWindow: 3.0)

        let applied96 = detection(rate: 96_000, source: .alacInput, at: 0)
        gate.didApply(
            applied96,
            previouslyApplied: detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: -1),
            at: t0
        )
        XCTAssertTrue(gate.lastApplyWasUpgrade)

        gate.noteTrackChanged(at: t0.addingTimeInterval(0.2))
        let next441 = detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: 0.3)
        XCTAssertEqual(
            gate.consider(next441, now: t0.addingTimeInterval(0.4)),
            .apply(next441)
        )
    }

    func testALACDowngradeAllowedAfterSettle() {
        var gate = FormatSwitchGate(settleWindow: 3.0)

        let applied96 = detection(rate: 96_000, source: .alacInput, at: 0)
        gate.didApply(
            applied96,
            previouslyApplied: detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: -1),
            at: t0
        )

        let next441 = detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: 4)
        XCTAssertEqual(
            gate.consider(next441, now: t0.addingTimeInterval(4)),
            .apply(next441)
        )
    }

    func testFixtureSimulate96ThenDelayed441MustNotRevert() {
        // Deterministic fixture requested in the bug report:
        // detect 96 → apply → delayed 44.1 within settle → must NOT revert.
        var gate = FormatSwitchGate(settleWindow: 3.0)
        var appliedRate: Double?

        let d96 = detection(rate: 96_000, source: .alacInput, at: 0)
        if case .apply(let accepted) = gate.consider(d96, now: t0) {
            gate.didApply(
                accepted,
                previouslyApplied: detection(rate: 44_100, bitDepth: 16, source: .alacInput, at: -2),
                at: t0
            )
            appliedRate = accepted.format.sampleRate
        }
        XCTAssertEqual(appliedRate, 96_000)

        let delayed441 = FormatParser.parse(
            line: #"Music: [com.apple.Music:ampplay] audioCapabilities: sdBitDepth = 16 bit, asbdSampleRate = 44.1 kHz"#,
            detectedAt: t0.addingTimeInterval(0.5)
        )
        XCTAssertNotNil(delayed441)
        XCTAssertEqual(
            gate.consider(delayed441!, now: t0.addingTimeInterval(0.6)),
            .ignore
        )
        XCTAssertEqual(gate.lastApplied?.format.sampleRate, 96_000)
        XCTAssertEqual(appliedRate, 96_000)
    }
}
