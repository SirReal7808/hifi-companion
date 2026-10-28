import AppKit
import Foundation

enum AppleScriptFallback {
    static let musicBundleID = "com.apple.Music"

    /// `tell application "Music"` launches Music when it is not running — check first.
    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).isEmpty
    }

    /// Sample rate of the current Music track in Hz, when Music exposes it via AppleScript.
    /// `NSAppleScript` is not thread-safe: call on the main thread only.
    @MainActor
    static func currentTrackSampleRate() -> Double? {
        guard isMusicRunning else { return nil }
        let source = """
        tell application "Music"
            if player state is not stopped then
                try
                    return sample rate of current track
                end try
            end if
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        let value = result.doubleValue
        return value > 0 ? value : nil
    }
}
