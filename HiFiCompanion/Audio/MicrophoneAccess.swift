import AVFoundation
import Foundation
import os.log

/// Input / “Microphone” TCC for BlackHole capture (v1). Settings can show Allowed while the
/// AVAudioApplication API still reports denied after ad-hoc re-signs — never treat the API
/// alone as proof capture will fail; always try opening the input and surface real errors.
enum MicrophoneAccess {
    enum Status: String {
        case granted
        case denied
        case undetermined
        case unknown
    }

    private static let log = Logger(subsystem: "com.hificompanion.app", category: "MicrophoneAccess")

    /// Best-effort granted: either modern or legacy API reports authorized.
    static var isGranted: Bool {
        status == .granted
    }

    static var status: Status {
        let audioApp = audioApplicationStatus()
        let capture = captureDeviceStatus()
        log.debug("mic status audioApp=\(audioApp.rawValue, privacy: .public) capture=\(capture.rawValue, privacy: .public)")
        if audioApp == .granted || capture == .granted {
            return .granted
        }
        if audioApp == .denied && capture == .denied {
            return .denied
        }
        if audioApp == .undetermined || capture == .undetermined {
            return .undetermined
        }
        // Mixed / unknown — do not claim denied.
        return .unknown
    }

    static var diagnosticSummary: String {
        "AVAudioApplication=\(audioApplicationStatus().rawValue) AVCaptureDevice=\(captureDeviceStatus().rawValue) effective=\(status.rawValue)"
    }

    /// Explicitly request if not already granted. Returns the post-request effective status.
    @discardableResult
    static func ensureRequested() async -> Status {
        if isGranted {
            return .granted
        }

        // Prefer AVAudioApplication on macOS 14+; also poke AVCaptureDevice when undetermined
        // so either TCC path can flip Settings → Allowed into a usable grant.
        if #available(macOS 14.0, *) {
            let granted = await requestAudioApplication()
            if granted { return .granted }
        }

        let captureGranted = await requestCaptureDevice()
        if captureGranted { return .granted }

        // Re-read — Settings may already be ON while request callbacks return false for a
        // stale code-signature identity; another API might still report granted.
        return status
    }

    /// True when we should show the System Settings / Microphone help string.
    /// Only when both APIs agree on denied (or request failed and status is clearly denied).
    static var shouldSurfaceDeniedHelp: Bool {
        status == .denied
    }

    static let settingsHelp =
        "Input access denied. System Settings → Privacy & Security → Microphone → enable HiFi Companion, then toggle Pass-through again. After a rebuild, turn Microphone off/on once for this app. Without Input access, BlackHole cannot be captured."

    // MARK: - APIs

    private static func audioApplicationStatus() -> Status {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .denied: return .denied
            case .undetermined: return .undetermined
            @unknown default: return .unknown
            }
        }
        return .unknown
    }

    private static func captureDeviceStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .unknown
        }
    }

    @available(macOS 14.0, *)
    private static func requestAudioApplication() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestCaptureDevice() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
