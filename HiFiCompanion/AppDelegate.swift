import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var smokeTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()

        if CommandLine.arguments.contains("--probe-mic") {
            smokeTask = Task { @MainActor in
                _ = await MicrophoneAccess.ensureRequested()
                print("PROBE_MIC: \(MicrophoneAccess.diagnosticSummary)")
                print("PROBE_MIC: isGranted=\(MicrophoneAccess.isGranted) status=\(MicrophoneAccess.status.rawValue)")
                fflush(stdout)
                AppModel.shared.stop()
                exit(MicrophoneAccess.isGranted ? 0 : 2)
            }
            return
        }

        if CommandLine.arguments.contains("--smoke-passthrough") {
            smokeTask = Task { @MainActor in
                // Allow device recovery + TCC prompts to settle.
                try? await Task.sleep(nanoseconds: 400_000_000)
                print("SMOKE_MIC: \(MicrophoneAccess.diagnosticSummary)")
                let code = await AppModel.shared.runPassThroughSmokeTest()
                AppModel.shared.stop()
                fflush(stdout)
                exit(code)
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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTask?.cancel()
        AppModel.shared.stop()
    }
}
