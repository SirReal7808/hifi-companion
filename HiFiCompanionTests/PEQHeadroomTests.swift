import XCTest

final class PEQHeadroomTests: XCTestCase {
    private let sr = 48_000.0

    func testFlatZeroOutHasNoWarning() {
        let bands = EQBand.defaultTenBands()
        XCTAssertEqual(PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr), 0, accuracy: 1e-9)
        XCTAssertEqual(PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: 0), 0, accuracy: 1e-9)
        XCTAssertFalse(PEQHeadroom.isClippingRisk(outputGainDB: 0, peakBoostDB: 0))
        let result = PEQHeadroom.applyManualOutputGain(requested: 0, bands: bands, sampleRate: sr)
        XCTAssertFalse(result.clippingWarning)
    }

    func testStackedBoostsForceCeilingDownWithAuto() {
        var bands = EQBand.defaultTenBands()
        if let i1 = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }),
           let i2 = bands.firstIndex(where: { abs($0.frequencyHz - 2_000) < 1 }) {
            bands[i1].gainDB = 9
            bands[i1].enabled = true
            bands[i2].gainDB = 9
            bands[i2].enabled = true
        }
        let result = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: 0,
            sampleRate: sr,
            autoOutputGain: true
        )
        XCTAssertGreaterThan(result.peakBoostDB, 9)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: result.peakBoostDB)
        XCTAssertEqual(result.outputGainDB, ceiling, accuracy: 1e-9)
        XCTAssertLessThan(result.outputGainDB, -9)
        XCTAssertFalse(result.clippingWarning)
        XCTAssertEqual(result.autoAdjustment, .lowerImmediate(ceiling))
        // Auto lands exactly on −peak: output + boost ≤ 0.
        XCTAssertLessThanOrEqual(result.outputGainDB + result.peakBoostDB, 1e-9)
    }

    func testClipDownIsImmediate() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: sr)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        let adjustment = PEQHeadroom.autoGainAdjustment(currentOutputGainDB: 0, peakBoostDB: boost)
        XCTAssertEqual(adjustment, .lowerImmediate(ceiling))

        let result = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: 0,
            sampleRate: sr,
            autoOutputGain: true
        )
        // Immediate path: published gain is already the ceiling (no ramp hold).
        XCTAssertEqual(result.outputGainDB, ceiling, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .lowerImmediate(ceiling))
    }

    func testAutoRaiseRampsToCeilingEndValue() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 12
            bands[i].enabled = true
        }
        let boosted = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: 0,
            sampleRate: sr,
            autoOutputGain: true
        )
        guard case .lowerImmediate(let low) = boosted.autoAdjustment else {
            return XCTFail("expected immediate lower")
        }
        XCTAssertEqual(boosted.outputGainDB, low, accuracy: 1e-9)

        // Shrink the boost; Auto plans a raise to the new ceiling (caller ramps ~2 s).
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 3
        }
        let shrunk = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: boosted.outputGainDB,
            sampleRate: sr,
            autoOutputGain: true
        )
        let newCeiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: shrunk.peakBoostDB)
        XCTAssertGreaterThan(newCeiling, boosted.outputGainDB)
        // Current gain held until ramp; end target is the new ceiling.
        XCTAssertEqual(shrunk.outputGainDB, boosted.outputGainDB, accuracy: 1e-9)
        XCTAssertEqual(shrunk.autoAdjustment, .raiseRamp(newCeiling))

        let mid = PEQHeadroom.rampOutputGainDB(
            from: boosted.outputGainDB,
            to: newCeiling,
            progress: 0.5
        )
        let end = PEQHeadroom.rampOutputGainDB(
            from: boosted.outputGainDB,
            to: newCeiling,
            progress: 1
        )
        XCTAssertEqual(
            mid,
            (boosted.outputGainDB + newCeiling) / 2,
            accuracy: 1e-9
        )
        XCTAssertEqual(end, newCeiling, accuracy: 1e-9)
        XCTAssertEqual(PEQHeadroom.autoRaiseDurationSeconds, 2.0, accuracy: 1e-9)
    }

    func testCheckingAutoWhileBelowCeilingPlansRaise() {
        let boost = 0.0
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        XCTAssertEqual(ceiling, 0, accuracy: 1e-9)
        let adjustment = PEQHeadroom.autoGainAdjustment(
            currentOutputGainDB: -9.5,
            peakBoostDB: boost
        )
        XCTAssertEqual(adjustment, .raiseRamp(0))
    }

    func testAutoOffKeepsManualGain() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 12
            bands[i].enabled = true
        }
        let result = PEQHeadroom.applyBandChange(
            bands: bands,
            outputGainDB: 0,
            sampleRate: sr,
            autoOutputGain: false
        )
        XCTAssertEqual(result.outputGainDB, 0, accuracy: 1e-9)
        // 0 + ~12 > 0 → real clipping warning.
        XCTAssertTrue(result.clippingWarning)
    }

    func testManualGainAboveZeroSumSetsWarning() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 12
            bands[i].enabled = true
        }
        // The reading the app warns with (highest over the common rates).
        let boost = PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: sr)
        let result = PEQHeadroom.applyManualOutputGain(
            requested: -boost + 1, // output + boost = +1 → clip risk
            bands: bands,
            sampleRate: sr
        )
        XCTAssertTrue(result.clippingWarning)
        // Exactly at 0 sum is not a warning.
        let edge = PEQHeadroom.applyManualOutputGain(
            requested: -boost,
            bands: bands,
            sampleRate: sr
        )
        XCTAssertFalse(edge.clippingWarning)
    }

    func testAutoCeilingIsMinusPeakWithNoMargin() {
        // Same convention as AutoEQ / graph tools: preamp = −peak (2026-11-15).
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        XCTAssertEqual(ceiling, -boost, accuracy: 1e-9)
        XCTAssertFalse(PEQHeadroom.isClippingRisk(outputGainDB: ceiling, peakBoostDB: boost))
        XCTAssertTrue(PEQHeadroom.isClippingRisk(outputGainDB: ceiling + 0.2, peakBoostDB: boost))
    }

    func testNarrowPeakBetweenGridPointsIsNotUnderRead() {
        // Q 10 at 10 kHz: the bare 256-point grid read ~5.47 dB for a +6 dB band.
        let band = EQBand(frequencyHz: 10_000, gainDB: 6, q: 10, filterType: .peaking)
        let boost = PEQHeadroom.peakBoostDB(bands: [band], sampleRate: sr)
        XCTAssertEqual(boost, 6, accuracy: 0.01)
        let narrow = EQBand(frequencyHz: 6_500, gainDB: 5, q: 8, filterType: .peaking)
        XCTAssertEqual(PEQHeadroom.peakBoostDB(bands: [narrow], sampleRate: 44_100), 5, accuracy: 0.01)
    }

    func testHighShelfNearNyquistReadsFullGain() {
        let shelf = EQBand(frequencyHz: 19_000, gainDB: 6, q: 0.7, filterType: .highShelf)
        XCTAssertEqual(PEQHeadroom.peakBoostDB(bands: [shelf], sampleRate: 44_100), 6, accuracy: 0.05)
        let mid = EQBand(frequencyHz: 12_000, gainDB: 6, q: 0.7, filterType: .highShelf)
        // At 96 kHz the shelf is matched to its 44.1 kHz shape (Q a little higher), which
        // overshoots the plateau slightly; the reading must still cover the full gain.
        let midBoost = PEQHeadroom.peakBoostDB(bands: [mid], sampleRate: 96_000)
        XCTAssertGreaterThanOrEqual(midBoost, 5.95)
        XCTAssertLessThan(midBoost, 6.3)
    }

    func testPeakMatchesDenseScanForMixedCurve() {
        let bands = [
            EQBand(frequencyHz: 105, gainDB: 5.5, q: 0.7, filterType: .lowShelf),
            EQBand(frequencyHz: 150, gainDB: -2, q: 0.8, filterType: .peaking),
            EQBand(frequencyHz: 2_500, gainDB: 3, q: 2, filterType: .peaking),
            EQBand(frequencyHz: 2_900, gainDB: 3, q: 6, filterType: .peaking),
            EQBand(frequencyHz: 8_700, gainDB: 4, q: 9, filterType: .peaking),
            EQBand(frequencyHz: 10_000, gainDB: 3, q: 0.7, filterType: .highShelf),
        ]
        for rate in [44_100.0, 48_000, 96_000] {
            // What the DSP runs at this rate (matched to the 44.1 kHz curve).
            let sections = ReferenceRateDesign.coefficients(bands, sampleRate: rate)
            var dense = 0.0
            let n = 200_000
            let lo = log(20.0), hi = log(rate * 0.5 - 1)
            for i in 0..<n {
                let hz = exp(lo + Double(i) / Double(n - 1) * (hi - lo))
                dense = max(dense, PEQHeadroom.cascadeMagnitudeDB(sections: sections, atHz: hz, sampleRate: rate))
            }
            XCTAssertEqual(PEQHeadroom.peakBoostDB(bands: bands, sampleRate: rate), dense, accuracy: 0.005, "rate \(rate)")
        }
    }

    func testSetSafeLowerIsImmediate() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 8
            bands[i].enabled = true
        }
        let result = PEQHeadroom.applySetSafe(
            bands: bands,
            outputGainDB: 0,
            sampleRate: sr
        )
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: result.peakBoostDB)
        XCTAssertEqual(result.outputGainDB, ceiling, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .lowerImmediate(ceiling))
        XCTAssertFalse(result.clippingWarning)
    }

    func testSetSafeRaiseEndsAtCeilingAfterRamp() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 6
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: sr)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        let manualCut = ceiling - 6
        let result = PEQHeadroom.applySetSafe(
            bands: bands,
            outputGainDB: manualCut,
            sampleRate: sr
        )
        // Hold current until ramp; end target is the ceiling.
        XCTAssertEqual(result.outputGainDB, manualCut, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .raiseRamp(ceiling))
        let end = PEQHeadroom.rampOutputGainDB(from: manualCut, to: ceiling, progress: 1)
        XCTAssertEqual(end, ceiling, accuracy: 1e-9)
        XCTAssertEqual(PEQHeadroom.autoRaiseDurationSeconds, 2.0, accuracy: 1e-9)
    }

    func testResetRaisesBelowZeroViaRampToZero() {
        let below: Double = -7.5
        let result = PEQHeadroom.applyResetBands(outputGainDB: below, sampleRate: sr)
        XCTAssertEqual(result.outputGainDB, below, accuracy: 1e-9)
        XCTAssertEqual(result.peakBoostDB, 0, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .raiseRamp(0))
        let end = PEQHeadroom.rampOutputGainDB(from: below, to: 0, progress: 1)
        XCTAssertEqual(end, 0, accuracy: 1e-9)
        XCTAssertTrue(result.bands.isEmpty)
    }

    func testResetLowersAboveZeroImmediately() {
        let result = PEQHeadroom.applyResetBands(outputGainDB: 3.0, sampleRate: sr)
        XCTAssertEqual(result.outputGainDB, 0, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .lowerImmediate(0))
        XCTAssertTrue(result.bands.isEmpty)
        XCTAssertFalse(result.clippingWarning)
    }

    func testResetAlreadyZeroLeavesGain() {
        let result = PEQHeadroom.applyResetBands(outputGainDB: 0, sampleRate: sr)
        XCTAssertEqual(result.outputGainDB, 0, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .leave)
        XCTAssertEqual(result.peakBoostDB, 0, accuracy: 1e-9)
        XCTAssertTrue(result.bands.isEmpty)
    }

    func testLowShelfBoostCountsTowardPeakBoost() {
        var bands = [EQBand.makeBand(frequencyHz: 120, filterType: .lowShelf, gainDB: 6, q: 0.7)]
        bands[0].enabled = true
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        XCTAssertGreaterThan(boost, 4.5)
        // Far above the shelf corner should be near dry.
        let high = PEQHeadroom.cascadeMagnitudeDB(bands: bands, atHz: 8_000, sampleRate: sr)
        XCTAssertLessThan(abs(high), 1.5)
    }

    func testHighShelfBoostCountsTowardPeakBoost() {
        var bands = [EQBand.makeBand(frequencyHz: 8_000, filterType: .highShelf, gainDB: 6, q: 0.7)]
        bands[0].enabled = true
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        XCTAssertGreaterThan(boost, 4.5)
        let low = PEQHeadroom.cascadeMagnitudeDB(bands: bands, atHz: 100, sampleRate: sr)
        XCTAssertLessThan(abs(low), 1.5)
    }

    func testProcessorAcceptsVariableBandCount() {
        let peq = PEQProcessor()
        peq.configure(sampleRate: sr, channelCount: 2)
        let bands = [
            EQBand.makeBand(frequencyHz: 1_000, filterType: .peaking, gainDB: 3),
            EQBand.makeBand(frequencyHz: 200, filterType: .lowShelf, gainDB: 2, q: 0.7)
        ]
        peq.setState(bands: bands, outputGainDB: 0, bypass: false)
        XCTAssertEqual(peq.currentBands.count, 2)
        XCTAssertGreaterThan(peq.peakBoostDB(), 2)
    }

    func testRelaunchEquivalentKeepsWarningWhileUnsafe() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        let unsafeGain = -boost + 2
        let stillRisk = PEQHeadroom.isClippingRisk(outputGainDB: unsafeGain, peakBoostDB: boost)
        XCTAssertTrue(stillRisk)
        // Flat + 0 after load must clear.
        XCTAssertFalse(PEQHeadroom.isClippingRisk(outputGainDB: 0, peakBoostDB: 0))
    }

    func testPerBandDisabledSkipsBiquadButLeavesOthers() {
        let peq = PEQProcessor()
        peq.configure(sampleRate: sr, channelCount: 1)
        var active = EQBand.makeBand(frequencyHz: 1_000, filterType: .peaking, gainDB: 12, q: 1.41)
        active.enabled = true
        var muted = EQBand.makeBand(frequencyHz: 1_000, filterType: .peaking, gainDB: 12, q: 1.41)
        muted.enabled = false

        // Disabled band alone must be audibly flat (unity through the processor).
        peq.setState(bands: [muted], outputGainDB: 0, bypass: false)
        var dry = [Float](repeating: 0.25, count: 64)
        dry.withUnsafeMutableBufferPointer { buf in
            peq.processInterleaved(buf.baseAddress!, frames: 64, channels: 1)
        }
        XCTAssertEqual(dry[32], 0.25, accuracy: 1e-4)

        // Enabled band at the same F/G/Q must color the signal.
        peq.setState(bands: [active], outputGainDB: 0, bypass: false)
        var wet = [Float](repeating: 0.25, count: 64)
        // Seed a short impulse-ish burst so the peaking filter has energy at 1 kHz.
        wet[0] = 1
        wet.withUnsafeMutableBufferPointer { buf in
            peq.processInterleaved(buf.baseAddress!, frames: 64, channels: 1)
        }
        let energy = wet.reduce(Float(0)) { $0 + abs($1) }
        XCTAssertGreaterThan(energy, 1.0)

        // Headroom / curve must ignore disabled bands.
        XCTAssertEqual(PEQHeadroom.peakBoostDB(bands: [muted], sampleRate: sr), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(PEQHeadroom.peakBoostDB(bands: [active], sampleRate: sr), 8)
    }

    func testBypassGainMatchOnAppliesOutputGain() {
        let peq = PEQProcessor()
        peq.configure(sampleRate: sr, channelCount: 2)
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 9
            bands[i].enabled = true
        }
        peq.setState(bands: bands, outputGainDB: -6, bypass: true, applyOutputGainWhenBypassed: true)

        var samples = [Float](repeating: 0.5, count: 64)
        samples.withUnsafeMutableBufferPointer { buf in
            peq.processInterleaved(buf.baseAddress!, frames: 32, channels: 2)
        }
        let expected = Float(0.5 * pow(10.0, -6.0 / 20.0))
        XCTAssertEqual(samples[0], expected, accuracy: 1e-5)
        XCTAssertEqual(samples[10], expected, accuracy: 1e-5)
    }

    func testBypassGainMatchOffIsTrueDryUnity() {
        let peq = PEQProcessor()
        peq.configure(sampleRate: sr, channelCount: 2)
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 9
            bands[i].enabled = true
        }
        peq.setState(bands: bands, outputGainDB: -6, bypass: true, applyOutputGainWhenBypassed: false)

        var samples = [Float](repeating: 0.5, count: 64)
        samples.withUnsafeMutableBufferPointer { buf in
            peq.processInterleaved(buf.baseAddress!, frames: 32, channels: 2)
        }
        XCTAssertEqual(samples[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(samples[10], 0.5, accuracy: 1e-5)
    }

    func testBandGainClampIsFourteen() {
        var band = EQBand.defaultTenBands()[5]
        band.gainDB = 20
        band.clamp()
        XCTAssertEqual(band.gainDB, 14, accuracy: 1e-9)
        band.gainDB = -20
        band.clamp()
        XCTAssertEqual(band.gainDB, -14, accuracy: 1e-9)
    }

    func testQStepsToTenth() {
        var band = EQBand.defaultTenBands()[0]
        band.q = 1.46
        band.clamp()
        XCTAssertEqual(band.q, 1.5, accuracy: 1e-9)
        // Floor is the DSP's Q (0.1), not 0 — the row must show what is applied.
        band.q = 0
        band.clamp()
        XCTAssertEqual(band.q, 0.1, accuracy: 1e-9)
    }

    func testHeadroomPeakBoostIsTheSameAt48And96k() {
        // Mert 2026-11-23: Auto Gain rose when the rate went 48 → 96 kHz.
        var band = EQBand.makeBand(frequencyHz: 9_000, filterType: .peaking, gainDB: 4.5, q: 2)
        band.enabled = true
        var low = EQBand.makeBand(frequencyHz: 7_000, filterType: .peaking, gainDB: 3, q: 1.5)
        low.enabled = true
        let bands = [band, low]
        let at441 = PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: 44_100)
        for rate in [48_000.0, 88_200, 96_000, 176_400, 192_000] {
            let value = PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: rate)
            XCTAssertEqual(value, at441, accuracy: 1e-9, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(value, PEQHeadroom.peakBoostDB(bands: bands, sampleRate: rate) - 1e-9)
        }
    }

    func testHeadroomPeakBoostNeverReadsBelowTheLiveRate() {
        var shelf = EQBand.makeBand(frequencyHz: 19_000, filterType: .highShelf, gainDB: 6, q: 0.707)
        shelf.enabled = true
        var peak = EQBand.makeBand(frequencyHz: 9_000, filterType: .peaking, gainDB: 4.5, q: 2)
        peak.enabled = true
        for rate in [32_000.0, 44_100, 48_000, 96_000, 192_000] {
            for bands in [[shelf], [peak], [shelf, peak]] {
                XCTAssertGreaterThanOrEqual(
                    PEQHeadroom.headroomPeakBoostDB(bands: bands, liveSampleRate: rate),
                    PEQHeadroom.peakBoostDB(bands: bands, sampleRate: rate) - 1e-9,
                    "rate \(rate)"
                )
            }
        }
    }
}

private extension EQBand {
    init(frequencyHz: Double, gainDB: Double, q: Double, filterType: EQFilterType) {
        self.init(id: UUID(), enabled: true, filterType: filterType, frequencyHz: frequencyHz, gainDB: gainDB, q: q)
    }
}
