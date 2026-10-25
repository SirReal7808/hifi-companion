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
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        smokeTask?.cancel()
        AppModel.shared.stop()
    }
}
