import Foundation

/// Apple Music decodes the next track about 20 s before the current one ends (gapless) and logs
/// its format then. Taken at face value, that reclocked the DAC near the end of the playing
/// track — a ~1 s gap there and the rest of the track resampled (audio-events.log, 2026-10-31:
/// "Time Travellers" 44.1 kHz, 96 kHz applied at 379 s of 402 s). A rate change is applied only
/// when the playing track (AppleScript `sample rate of current track`) has that rate; otherwise
/// it waits for the track change. Pure; unit-tested.
enum NextTrackGuard {
    enum Decision: Equatable {
        /// The playing track has this rate (or there is nothing to change): apply now.
        case apply
        /// The playing track has another rate: this is the next track — hold it.
        case holdForNextTrack
    }

    static func decide(candidateRate: Double, dacRate: Double?, playingTrackRate: Double?) -> Decision {
        // Not a rate change (bit depth only, or first match): nothing to protect.
        guard let dacRate, abs(candidateRate - dacRate) >= 1 else { return .apply }
        // AppleScript unavailable: keep the old behavior rather than never switching.
        guard let playingTrackRate else { return .apply }
        return abs(playingTrackRate - candidateRate) < 1 ? .apply : .holdForNextTrack
    }

    /// At a track change: what the DAC should run now. The playing track's rate is the truth
    /// (AppleScript reports it right: 44100 / 96000 checked 2026-10-31); a held detection with
    /// that rate also gives the bit depth. nil = nothing to change. Without AppleScript, a held
    /// detection is applied as is.
    static func formatAtTrackChange(
        held: AudioFormatInfo?,
        playingTrackRate: Double?,
        dacFormat: AudioFormatInfo?
    ) -> AudioFormatInfo? {
        guard let playingTrackRate else { return held }
        let format: AudioFormatInfo
        if let held, abs(held.sampleRate - playingTrackRate) < 1 {
            format = held
        } else {
            format = AudioFormatInfo(sampleRate: playingTrackRate, bitDepth: dacFormat?.bitDepth ?? 24)
        }
        if let dacFormat, abs(dacFormat.sampleRate - format.sampleRate) < 1, held == nil { return nil }
        return format
    }

    /// Right after a track change, AppleScript may still report the previous track. Only the
    /// previous track's rate can be that stale answer: any other rate is the new track, applied
    /// at once even when it disagrees with the held detection (log 2026-10-31 21:22: a bogus
    /// 48 kHz hold made a 96 kHz answer wait for the 2 s final attempt). The previous track's
    /// rate is the last accepted one, not the DAC's — the lock or a failed switch can leave the
    /// DAC elsewhere.
    static func shouldWaitForAppleScript(heldRate: Double?, playingTrackRate: Double?, previousTrackRate: Double?) -> Bool {
        guard let heldRate, let playingTrackRate, abs(heldRate - playingTrackRate) >= 1 else { return false }
        guard let previousTrackRate else { return true }
        return abs(playingTrackRate - previousTrackRate) < 1
    }
}
