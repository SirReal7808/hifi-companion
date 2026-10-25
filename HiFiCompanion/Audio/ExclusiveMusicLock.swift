import Foundation

/// Soft lock so Apple Music mode only switches the DAC while Music is alone on that device.
///
/// Competing clients must remain audible past `lockGrace` before locking (softens notification
/// chirps). After they stop, `unlockGrace` must elapse before unlocking and allowing catch-up.
struct ExclusiveMusicLock: Sendable {
    enum Event: Equatable, Sendable {
        case locked
        case unlocked
        case unchanged
    }

    var lockGrace: TimeInterval
    var unlockGrace: TimeInterval

    private(set) var isLocked = false
    private var competingSince: Date?
    private var clearSince: Date?

    init(lockGrace: TimeInterval = 0.85, unlockGrace: TimeInterval = 0.6) {
        self.lockGrace = lockGrace
        self.unlockGrace = unlockGrace
    }

    /// Feed whether any non-Music audible client is present on the pinned DAC.
    @discardableResult
    mutating func update(competingAudible: Bool, now: Date = Date()) -> Event {
        if competingAudible {
            clearSince = nil
            if competingSince == nil {
                competingSince = now
            }
            if !isLocked,
               let start = competingSince,
               now.timeIntervalSince(start) >= lockGrace {
                isLocked = true
                return .locked
            }
            return .unchanged
        }

        competingSince = nil
        if !isLocked {
            clearSince = nil
            return .unchanged
        }

        if clearSince == nil {
            clearSince = now
        }
        if let start = clearSince, now.timeIntervalSince(start) >= unlockGrace {
            isLocked = false
            clearSince = nil
            return .unlocked
        }
        return .unchanged
    }

    mutating func reset() {
        isLocked = false
        competingSince = nil
        clearSince = nil
    }
}
