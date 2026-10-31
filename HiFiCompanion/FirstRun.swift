import Foundation

/// When the first-run explainer shows by itself at launch (docs/redesign-0.3.md → First run).
/// Pure; unit-tested.
enum FirstRun {
    enum LaunchDecision: Equatable {
        /// Nothing to do.
        case none
        /// An existing user already saw the permission prompt: never show it.
        case markSeen
        /// Fresh install, first launch: show it once (it shows again before the first enable).
        case show
    }

    static func launchDecision(welcomeSeen: Bool, usedBefore: Bool, firstLaunchDone: Bool) -> LaunchDecision {
        if welcomeSeen { return .none }
        if usedBefore { return .markSeen }
        return firstLaunchDone ? .none : .show
    }
}
