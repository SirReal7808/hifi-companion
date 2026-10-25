import Foundation

enum AppleScriptFallback {
    /// Sample rate of the current Music track in Hz, when Music exposes it via AppleScript.
    static func currentTrackSampleRate() -> Double? {
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
