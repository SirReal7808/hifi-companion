import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var smokeTask: Task<Void, Never>?

    /// `xcodebuild test` hosts the unit tests inside this app. Then the app must not start
    /// `log stream`, poll devices, or switch the DAC's SB while someone may be listening.
    static var isHostingUnitTests: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Self.isHostingUnitTests {
            print("HiFiCompanion: hosting unit tests — app services not started")
            fflush(stdout)
            return
        }
        // Menu panel, Settings tabs, welcome and EQ windows as PNGs (visual check). Services are
        // not started, so this never touches the output or the tap while someone listens.
        if let idx = CommandLine.arguments.firstIndex(of: "--ui-screenshots"),
           CommandLine.arguments.indices.contains(idx + 1) {
            let directory = CommandLine.arguments[idx + 1]
            smokeTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                let results = await AuxWindows.shared.captureForAutomation(to: directory)
                for (name, ok) in results.sorted(by: { $0.key < $1.key }) {
                    print("UI_SHOT: \(name) ok=\(ok)")
                }
                fflush(stdout)
                exit(results.values.allSatisfy { $0 } ? 0 : 1)
            }
            return
        }
        // Bit-exact check of the flat-equalizer path (scripts/null-test.sh). Plays a soft test
        // file on the current output — audible — so it only runs when asked for.
        if let idx = CommandLine.arguments.firstIndex(of: "--null-test") {
            let args = CommandLine.arguments
            let reportPath = args.indices.contains(idx + 1) && !args[idx + 1].hasPrefix("-") ? args[idx + 1] : nil
            smokeTask = Task { @MainActor in
                let exact = await NullTestRunner.run(reportPath: reportPath)
                fflush(stdout)
                exit(exact ? 0 : 1)
            }
            return
        }

        AppModel.shared.start()
        Updater.shared.start()
        // Prove which binary is running (Spotlight often keeps a stale ~/Applications copy).
        let exe = Bundle.main.executablePath ?? "?"
        let ver = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        print("HiFiCompanion launch stamp=\(PEQPanelController.buildStamp) ver=\(ver) exe=\(exe)")
        fflush(stdout)

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
                // `--eq-appearance light|dark`: this run only; the saved preference is untouched.
                if let idx = CommandLine.arguments.firstIndex(of: "--eq-appearance"),
                   CommandLine.arguments.indices.contains(idx + 1),
                   let pref = AppearancePreference(rawValue: CommandLine.arguments[idx + 1]),
                   let window = PEQPanelController.shared.windowForAutomation {
                    pref.apply(to: window)
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                do {
                    let n = AppModel.shared.peq.bands.count
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: n))
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let exe = Bundle.main.executablePath ?? "?"
                    print("EQ_OPEN: bands=\(n) expect=\(expect) \(sizing) exe=\(exe)")
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
                // Regression: a reopened window must re-measure the side glass, or H(N) falls
                // back to `sideControlsHeight` and clips Add Band / Reset under the window edge.
                if CommandLine.arguments.contains("--eq-reopen") {
                    PEQPanelController.shared.close()
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    AppModel.shared.showPEQPanel()
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    let n = AppModel.shared.peq.bands.count
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: n))
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let remeasured = PEQPanelMetrics.measuredSideHeight > 40
                    print("EQ_REOPEN: bands=\(n) expect=\(expect) \(sizing) \(remeasured ? "OK" : "FAIL side not re-measured")")
                    if let shotIdx = CommandLine.arguments.firstIndex(of: "--eq-screenshot-reopen"),
                       CommandLine.arguments.indices.contains(shotIdx + 1) {
                        let ok = PEQPanelController.shared.testCapturePNG(to: CommandLine.arguments[shotIdx + 1])
                        print("EQ_SHOT_REOPEN: ok=\(ok)")
                    }
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--eq-add-one") {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let before = AppModel.shared.peq.bands.count
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        _ = AppModel.shared.peq.addBand()
                    }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    let after = AppModel.shared.peq.bands.count
                    let visible = PEQPanelController.shared.isVisible
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: after))
                    print("EQ_ADD_ONE: before=\(before) after=\(after) visible=\(visible) expect=\(expect) \(sizing) \(after == before + 1 && visible ? "OK" : "FAIL")")
                    fflush(stdout)
                }
                if CommandLine.arguments.contains("--eq-delete-one") {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let before = AppModel.shared.peq.bands.count
                    if let id = AppModel.shared.peq.bands.last?.id {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) {
                            AppModel.shared.peq.removeBand(id: id)
                        }
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let after = AppModel.shared.peq.bands.count
                    let visible = PEQPanelController.shared.isVisible
                    let sizing = PEQPanelController.shared.testSizingSummaryForAutomation()
                    let expect = Int(PEQPanelMetrics.contentHeight(bandCount: after))
                    print("EQ_DELETE_ONE: before=\(before) after=\(after) visible=\(visible) expect=\(expect) \(sizing) \(before > after && visible ? "OK" : "FAIL")")
                    fflush(stdout)
                }
                // Stress: grow to 10 bands then shrink to 4, logging height each step.
                if CommandLine.arguments.contains("--eq-stress-bands") {
                    let snap: @MainActor (String) -> Void = { tag in
                        let n = AppModel.shared.peq.bands.count
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
                    while AppModel.shared.peq.bands.count < EQBand.maxBandCount {
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { _ = AppModel.shared.peq.addBand() }
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        PEQPanelController.shared.resizeToFitContent()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        snap("add")
                        if AppModel.shared.peq.bands.count == 8,
                           let shotIdx = CommandLine.arguments.firstIndex(of: "--eq-screenshot-8"),
                           CommandLine.arguments.indices.contains(shotIdx + 1) {
                            let path = CommandLine.arguments[shotIdx + 1]
                            let ok = PEQPanelController.shared.testCapturePNG(to: path)
                            print("EQ_SHOT8: path=\(path) ok=\(ok)")
                            fflush(stdout)
                        }
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
                    while AppModel.shared.peq.bands.count > 4 {
                        guard let id = AppModel.shared.peq.bands.last?.id else { break }
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { AppModel.shared.peq.removeBand(id: id) }
                        try? await Task.sleep(nanoseconds: 650_000_000)
                        PEQPanelController.shared.resizeToFitContent()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        snap("del")
                    }
                    PEQPanelController.shared.resizeToFitContent()
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    snap("done")
                    if let shotIdx = CommandLine.arguments.firstIndex(of: "--eq-screenshot-4"),
                       CommandLine.arguments.indices.contains(shotIdx + 1) {
                        let path = CommandLine.arguments[shotIdx + 1]
                        let ok = PEQPanelController.shared.testCapturePNG(to: path)
                        print("EQ_SHOT4: path=\(path) ok=\(ok)")
                        fflush(stdout)
                    }
                }
                if let idx = CommandLine.arguments.firstIndex(of: "--eq-demo-frames"),
                   CommandLine.arguments.indices.contains(idx + 1) {
                    await Self.captureSweepDemoFrames(toDirectory: CommandLine.arguments[idx + 1])
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
                let publishedBand = model.peq.bands.first(where: { abs($0.frequencyHz - 1_000) < 1 })?.gainDB ?? -1
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

    /// Dock icon click while already active: bring a lost EQ window back (see `recoverIfLost`).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { PEQPanelController.shared.recoverIfLost(reason: "Dock reopen") }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTask?.cancel()
        AppModel.shared.stop()
    }
}

// MARK: - README demo frames

extension AppDelegate {
    /// `--eq-demo-frames <dir>` (with `--show-eq --eq-unlock-controls`): loads a demo curve,
    /// sweeps the needle (no tone; the bridge is never touched), presses FIX PEAK and saves
    /// one JPEG per frame (`frame-0001.jpg` …) for the README GIF, then quits.
    /// It edits and saves the EQ like a user would: back up the app's defaults first.
    @MainActor
    static func captureSweepDemoFrames(toDirectory dir: String) async {
        let model = AppModel.shared
        let peq = model.peq
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        peq.resetFlat()
        let demoCurve: [(EQFilterType, Double, Double, Double)] = [
            (.lowShelf, 105, 3.5, 0.7),
            (.peaking, 230, -2, 1.2),
            (.peaking, 1_800, 1.5, 1.0),
            (.highShelf, 10_000, -1.5, 0.7),
        ]
        for (type, hz, gain, q) in demoCurve {
            guard let id = peq.addBand() else { break }
            peq.updateBand(id: id) {
                $0.filterType = type
                $0.frequencyHz = hz
                $0.gainDB = gain
                $0.q = q
                $0.enabled = true
            }
        }
        peq.setSweepNeedle(hz: 1_000)
        model.previewSweepNeedleForAutomation(atHz: nil)
        PEQPanelController.shared.resizeToFitContent()
        try? await Task.sleep(nanoseconds: 600_000_000)

        var frame = 0
        func capture(_ count: Int = 1) async {
            for _ in 0..<count {
                try? await Task.sleep(nanoseconds: 40_000_000)
                frame += 1
                let path = (dir as NSString).appendingPathComponent(String(format: "frame-%04d.jpg", frame))
                _ = PEQPanelController.shared.testCapturePNG(to: path)
            }
        }
        /// Log-frequency move with ease-in-out, one capture per step.
        func sweep(from a: Double, to b: Double, steps: Int) async {
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let hz = exp(log(a) + (log(b) - log(a)) * eased)
                model.previewSweepNeedleForAutomation(atHz: hz)
                await capture()
            }
        }

        await capture(10)                         // parked needle
        await sweep(from: 1_000, to: 7_000, steps: 26)
        await sweep(from: 7_000, to: 2_200, steps: 20)
        await sweep(from: 2_200, to: 3_200, steps: 12)
        await capture(8)                          // holding on the peak
        model.previewSweepNeedleForAutomation(atHz: nil)
        await capture(6)
        _ = peq.applySweepPeak()
        PEQPanelController.shared.resizeToFitContent()
        try? await Task.sleep(nanoseconds: 400_000_000)
        await capture(36)                         // result

        print("EQ_DEMO: dir=\(dir) frames=\(frame)")
        fflush(stdout)
        model.stop()
        exit(0)
    }
}
