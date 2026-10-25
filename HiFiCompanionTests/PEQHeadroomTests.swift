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
        // Margin only for auto: output + boost should be ≤ −0.5.
        XCTAssertLessThanOrEqual(result.outputGainDB + result.peakBoostDB, -PEQHeadroom.headroomDB + 1e-9)
    }

    func testClipDownIsImmediate() {
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
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
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
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

    func testMarginZoneIsNotAWarning() {
        // Auto ceiling uses 0.5 dB margin; sitting between −boost−0.5 and −boost is still safe.
        var bands = EQBand.defaultTenBands()
        if let i = bands.firstIndex(where: { abs($0.frequencyHz - 1_000) < 1 }) {
            bands[i].gainDB = 10
            bands[i].enabled = true
        }
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
        let ceiling = PEQHeadroom.safeCeilingOutputGainDB(peakBoostDB: boost)
        XCTAssertEqual(ceiling, -boost - 0.5, accuracy: 1e-9)
        let inMargin = ceiling + 0.2 // still ≤ 0 sum
        XCTAssertFalse(PEQHeadroom.isClippingRisk(outputGainDB: inMargin, peakBoostDB: boost))
        XCTAssertTrue(inMargin > ceiling)
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
        let boost = PEQHeadroom.peakBoostDB(bands: bands, sampleRate: sr)
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
        XCTAssertTrue(result.bands.allSatisfy { abs($0.gainDB) < 1e-9 })
    }

    func testResetLowersAboveZeroImmediately() {
        let result = PEQHeadroom.applyResetBands(outputGainDB: 3.0, sampleRate: sr)
        XCTAssertEqual(result.outputGainDB, 0, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .lowerImmediate(0))
        XCTAssertFalse(result.clippingWarning)
    }

    func testResetAlreadyZeroLeavesGain() {
        let result = PEQHeadroom.applyResetBands(outputGainDB: 0, sampleRate: sr)
        XCTAssertEqual(result.outputGainDB, 0, accuracy: 1e-9)
        XCTAssertEqual(result.autoAdjustment, .leave)
        XCTAssertEqual(result.peakBoostDB, 0, accuracy: 1e-9)
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
        band.q = 0
        band.clamp()
        XCTAssertEqual(band.q, 0, accuracy: 1e-9)
    }
}
