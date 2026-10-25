import Foundation

/// Decides whether a freshly parsed Music format should be applied to the DAC.
///
/// Ports the useful parts of FantasticSkyBaby / LosslessSwitcher switch-back protection:
/// - settle window after an upswitch
/// - prefer higher-priority sources (ALAC Input over AudioQueue / audioCapabilities)
/// - require detections newer than the last applied switch
/// - do not re-apply a previous lower rate while a newer higher-rate switch is settling
/// - allow immediate high-priority downgrade only when Music reports a track change
struct FormatSwitchGate: Sendable {
    enum Decision: Equatable, Sendable {
        case apply(FormatDetection)
        case ignore
    }

    /// After an upswitch, ignore lower-rate detections for this long unless a track change occurred.
    var settleWindow: TimeInterval
    /// Track-change window during which an ALAC downgrade may bypass settle.
    var trackChangeWindow: TimeInterval

    private(set) var lastApplied: FormatDetection?
    private(set) var lastAppliedAt: Date?
    private(set) var lastApplyWasUpgrade = false
    private(set) var lastTrackChangeAt: Date?

    init(settleWindow: TimeInterval = 3.0, trackChangeWindow: TimeInterval = 3.0) {
        self.settleWindow = settleWindow
        self.trackChangeWindow = trackChangeWindow
    }

    mutating func noteTrackChanged(at now: Date = Date()) {
        lastTrackChangeAt = now
    }

    mutating func consider(_ candidate: FormatDetection, now: Date = Date()) -> Decision {
        guard let last = lastApplied, let appliedAt = lastAppliedAt else {
            return .apply(candidate)
        }

        if candidate.format == last.format {
            return .ignore
        }

        // Require a detection strictly newer than the one we last applied.
        if candidate.detectedAt <= last.detectedAt {
            return .ignore
        }

        let secondsSinceApply = now.timeIntervalSince(appliedAt)
        let inSettle = secondsSinceApply < settleWindow
        let recentTrackChange = lastTrackChangeAt.map { now.timeIntervalSince($0) < trackChangeWindow } ?? false
        let isUpgrade = candidate.format.sampleRate > last.format.sampleRate + 1
        let isDowngrade = candidate.format.sampleRate < last.format.sampleRate - 1

        if isUpgrade {
            return .apply(candidate)
        }

        if inSettle {
            // Classic switch-back: after upswitching to 96, teardown / AudioQueue /
            // audioCapabilities still emit the previous 44.1. Drop them.
            if isDowngrade {
                if recentTrackChange, candidate.source >= .alacInput {
                    return .apply(candidate)
                }
                return .ignore
            }

            // Same rate, bit-depth change: equal-or-higher priority only.
            if candidate.source < last.source {
                return .ignore
            }
            return .apply(candidate)
        }

        // Past settle: still reject low-priority downgrades overriding a higher-priority apply.
        if isDowngrade, candidate.source < last.source {
            return .ignore
        }
        if isDowngrade, candidate.source < .alacInput, last.source >= .alacInput {
            return .ignore
        }

        return .apply(candidate)
    }

    mutating func didApply(_ detection: FormatDetection, previouslyApplied: FormatDetection?, at now: Date = Date()) {
        let wasUpgrade: Bool
        if let previous = previouslyApplied {
            wasUpgrade = detection.format.sampleRate > previous.format.sampleRate + 1
        } else {
            wasUpgrade = false
        }
        lastApplied = detection
        lastAppliedAt = now
        lastApplyWasUpgrade = wasUpgrade
    }

    mutating func reset() {
        lastApplied = nil
        lastAppliedAt = nil
        lastApplyWasUpgrade = false
        lastTrackChangeAt = nil
    }
}
