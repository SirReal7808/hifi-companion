import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var smokeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()

        if CommandLine.arguments.contains("--smoke-passthrough") {
            smokeTask = Task { @MainActor in
                // Allow device recovery + TCC prompts to settle.
                try? await Task.sleep(nanoseconds: 400_000_000)
                let code = await AppModel.shared.runPassThroughSmokeTest()
                AppModel.shared.stop()
                fflush(stdout)
                exit(code)
            }
            return
        }

        // PT on → change DAC rate → graph must rebuild; PEQ coeffs must be live.
        if CommandLine.arguments.contains("--smoke-rate-eq") {
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                let model = AppModel.shared
                await model.applyPassThroughForAutomation(enabled: true)
                guard model.isBridgeRunning else {
                    print("SMOKE_RATE_EQ: FAIL PT did not start (\(model.lastError ?? "nil"))")
                    model.stop()
                    exit(1)
                }
                let startHz = model.graphSampleRateForAutomation()
                print("SMOKE_RATE_EQ: started graphHz=\(startHz)")

                // Flip between 44.1 and 96 (whichever we are not on).
                let targetHz = abs(startHz - 96_000) < 1.0 ? 44_100.0 : 96_000.0
                let rateOK = await model.forceDACRateChangeForAutomation(sampleRate: targetHz)
                let afterHz = model.graphSampleRateForAutomation()
                print("SMOKE_RATE_EQ: after rebuild want=\(targetHz) graph=\(afterHz) rateOK=\(rateOK)")

                let eqOK = model.proveTestEQLiveForAutomation(gainDB: 9)
                await model.applyPassThroughForAutomation(enabled: false)
                model.stop()
                let ok = rateOK && eqOK && abs(afterHz - targetHz) < 1.0
                print("SMOKE_RATE_EQ: \(ok ? "OK" : "FAIL") rateOK=\(rateOK) eqOK=\(eqOK)")
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }

        // Enable PT, print meter lines for N seconds (external afplay/Music can run alongside).
        if let holdIdx = CommandLine.arguments.firstIndex(of: "--hold-passthrough-seconds"),
           CommandLine.arguments.indices.contains(holdIdx + 1),
           let secs = Double(CommandLine.arguments[holdIdx + 1]), secs > 0 {
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                await AppModel.shared.applyPassThroughForAutomation(enabled: true)
                let deadline = Date().addingTimeInterval(secs)
                var peak: Float = 0
                while Date() < deadline {
                    let m = AppModel.shared.bridgeMeterForAutomation()
                    peak = max(peak, m.capturePeakRMS)
                    print("HOLD_METER peak=\(m.capturePeakRMS) maxPeak=\(peak) hearing=\(m.isHearingAudio) cb=\(m.captureCallbacks) out=\(m.outputDeviceID)")
                    fflush(stdout)
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                let ok = peak >= 0.004
                print("HOLD_RESULT maxPeak=\(peak) ok=\(ok)")
                await AppModel.shared.applyPassThroughForAutomation(enabled: false)
                AppModel.shared.stop()
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }

        // Visual / UI capture: open EQ panel.
        // `--eq-unlock-controls` enables band × / Add / Reset / bypass without a live bridge.
        // `--eq-enable-pt` also starts pass-through (after the panel is shown).
        // `--eq-delete-one` removes one band after layout settles (regression for × crash).
        if CommandLine.arguments.contains("--show-eq") {
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                if CommandLine.arguments.contains("--eq-unlock-controls") {
                    AppModel.shared.unlockEQControlsForTesting()
                }
                AppModel.shared.showPEQPanel()
                try? await Task.sleep(nanoseconds: 700_000_000)
                do {
                    let n = AppModel.shared.peqBands.count
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: n))
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    print("EQ_OPEN: bands=\(n) expect=\(expect) \(sizing)")
                    fflush(stdout)
                }
                if let shotIdx = CommandLine.arguments.firstIndex(of: "--eq-screenshot"),
                   CommandLine.arguments.indices.contains(shotIdx + 1) {
                    let path = CommandLine.arguments[shotIdx + 1]
                    let ok = PEQPanelController.shared.testCapturePNG(to: path)
                    print("EQ_SHOT: path=\(path) ok=\(ok)")
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--eq-enable-pt") {
                    await AppModel.shared.applyPassThroughForAutomation(enabled: true)
                }
                if CommandLine.arguments.contains("--eq-add-one") {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let before = AppModel.shared.peqBands.count
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        _ = AppModel.shared.addPEQBand()
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let after = AppModel.shared.peqBands.count
                    let visible = PEQPanelController.shared.isVisible
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: after))
                    print("EQ_ADD_ONE: before=\(before) after=\(after) visible=\(visible) expect=\(expect) \(sizing) \(after == before + 1 && visible ? "OK" : "FAIL")")
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--eq-delete-one") {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let before = AppModel.shared.peqBands.count
                    if let id = AppModel.shared.peqBands.last?.id {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            AppModel.shared.removePEQBand(id: id)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let after = AppModel.shared.peqBands.count
                    let visible = PEQPanelController.shared.isVisible
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: after))
                    print("EQ_DELETE_ONE: before=\(before) after=\(after) visible=\(visible) expect=\(expect) \(sizing) \(before > after && visible ? "OK" : "FAIL")")
                    fflush(stdout)
                }
                // Stress: grow to 10 bands then shrink to 4, logging height each step.
                if CommandLine.arguments.contains("--eq-stress-bands") {
                    let snap: @MainActor (String) -> Void = { tag in
                        let n = AppModel.shared.peqBands.count
                        let expect = Int(PEQPanelMetrics.contentHeight(bandCount: n))
                        let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                        let frame = Int(PEQPanelController.shared.testFrameHeightForAutomation().rounded())
                        let ok = abs(frame - expect) <= 1
                        print("EQ_STRESS: \(tag) bands=\(n) expect=\(expect) \(sizing) \(ok ? "OK" : "FAIL")")
                        fflush(stdout)
                    }
                    // Let initial verify passes finish before measuring.
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    PEQPanelController.shared.resizeToFitContent()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    snap("start")
                    while AppModel.shared.peqBands.count < EQBand.maxBandCount {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { _ = AppModel.shared.addPEQBand() }
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        PEQPanelController.shared.resizeToFitContent()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        snap("add")
                    }
                    PEQPanelController.shared.resizeToFitContent()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if let shotIdx = CommandLine.arguments.firstIndex(of: "--eq-screenshot-10"),
                       CommandLine.arguments.indices.contains(shotIdx + 1) {
                        let path = CommandLine.arguments[shotIdx + 1]
                        let ok = PEQPanelController.shared.testCapturePNG(to: path)
                        print("EQ_SHOT10: path=\(path) ok=\(ok)")
                        fflush(stdout)
                    }
                    while AppModel.shared.peqBands.count > 4 {
                        guard let id = AppModel.shared.peqBands.last?.id else { break }
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { AppModel.shared.removePEQBand(id: id) }
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        PEQPanelController.shared.resizeToFitContent()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        snap("del")
                    }
                    PEQPanelController.shared.resizeToFitContent()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    snap("done")
                }
            }
            return
        }

        // PT on → begin Sweep tone without Music; prove IO renders and oscillator is live.
        if CommandLine.arguments.contains("--smoke-sweep") {
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                let model = AppModel.shared
                await model.applyPassThroughForAutomation(enabled: true)
                guard model.isBridgeRunning else {
                    print("SMOKE_SWEEP: FAIL PT not running (\(model.lastError ?? "nil"))")
                    model.stop()
                    exit(1)
                }
                // Engine must stay down while idle so Music/PT keeps the DAC.
                try? await Task.sleep(nanoseconds: 800_000_000)
                let bridge = model.passThroughBridgeForAutomation()
                let idleEngine = bridge.isDACSweepEngineRunningForAutomation()
                print("SMOKE_SWEEP: engine@idle=\(idleEngine)")
                model.beginPEQSweep(atHz: 1_000)
                try? await Task.sleep(nanoseconds: 800_000_000)
                let audible = bridge.isSweepToneAudible
                let engineDuring = bridge.isDACSweepEngineRunningForAutomation()
                let counts = bridge.ioCallbackCountsForAutomation()
                let path = model.pathStatusText
                model.endPEQSweep()
                try? await Task.sleep(nanoseconds: 200_000_000)
                let engineAfter = bridge.isDACSweepEngineRunningForAutomation()
                await model.applyPassThroughForAutomation(enabled: false)
                model.stop()
                // Without Music the aggregate stays cold → Sweep uses the on-demand DAC
                // engine; it must start for the gesture and stop on release.
                let ok = !idleEngine && audible && engineDuring && !engineAfter
                print("SMOKE_SWEEP: \(ok ? "OK" : "FAIL") audible=\(audible) idle=\(idleEngine) during=\(engineDuring) after=\(engineAfter) counts=\(counts) path=\(path)")
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }

        // Enable PT → open PEQ panel → set live 1 kHz gain → verify published state.
        if CommandLine.arguments.contains("--smoke-test-eq-ui") {
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                let model = AppModel.shared
                await model.applyPassThroughForAutomation(enabled: true)
                guard model.isBridgeRunning else {
                    print("EQ_UI: FAIL PT not running (\(model.lastError ?? "nil"))")
                    model.stop()
                    exit(1)
                }
                model.showPEQPanel()
                try? await Task.sleep(nanoseconds: 300_000_000)
                let panelVisible = PEQPanelController.shared.isVisible
                model.setEQGainForAutomation(9)
                try? await Task.sleep(nanoseconds: 150_000_000)
                let publishedBand = model.peqBands.first(where: { abs($0.frequencyHz - 1_000) < 1 })?.gainDB ?? -1
                let bridge = model.bridgeMeterForAutomation()
                let liveOK = model.proveTestEQLiveForAutomation(gainDB: 9)
                model.setEQGainForAutomation(9)
                print("EQ_UI: panelVisible=\(panelVisible) band1k=\(publishedBand) path=\(model.pathStatusText) status=\(model.eqStatusText) hearing=\(bridge.isHearingAudio) liveOK=\(liveOK)")
                let ok = panelVisible && abs(publishedBand - 9) < 0.01 && liveOK && model.isEQActive
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                model.setEQGainForAutomation(0)
                await model.applyPassThroughForAutomation(enabled: false)
                PEQPanelController.shared.close()
                model.stop()
                print("EQ_UI: \(ok ? "OK" : "FAIL")")
                fflush(stdout)
                exit(ok ? 0 : 1)
            }
            return
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTask?.cancel()
        AppModel.shared.stop()
    }
}
