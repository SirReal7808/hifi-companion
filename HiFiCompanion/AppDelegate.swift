import AppKit

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
