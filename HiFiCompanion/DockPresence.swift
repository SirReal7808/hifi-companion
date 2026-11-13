import AppKit

/// The app is a menu bar app (`LSUIElement`, `.accessory`): no Dock icon and no ⌘Tab entry.
/// While one of its windows (EQ, Settings, Welcome) is open it becomes a regular app, so
/// ⌘Tab and the Dock bring that window back after another app took the focus. When the
/// last of them closes it goes back to `.accessory`.
@MainActor
enum DockPresence {
    private static var closeObserver: NSObjectProtocol?

    /// Call right before an app window is shown (before `NSApp.activate`).
    static func windowWillShow() {
        installCloseObserverIfNeeded()
        apply(.regular)
    }

    /// Re-check after an app window closed or was ordered out.
    static func refresh() {
        // Next turn: the closing window is off screen by then.
        DispatchQueue.main.async {
            // Hidden with ⌘H: windows report not visible but are still open; stay in ⌘Tab.
            guard !NSApp.isHidden else { return }
            apply(activationPolicy(hasOpenWindow: hasOpenAppWindow))
        }
    }

    nonisolated static func activationPolicy(hasOpenWindow: Bool) -> NSApplication.ActivationPolicy {
        hasOpenWindow ? .regular : .accessory
    }

    private static var hasOpenAppWindow: Bool {
        PEQPanelController.shared.isVisible || AuxWindows.shared.hasOpenWindow
    }

    private static func apply(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        if policy == .accessory, NSApp.isActive {
            // Otherwise the app stays frontmost with no window and the previous app's menu
            // bar does not come back until a click. Hiding hands the focus back; unhide
            // without activating so the menu bar panel opens normally afterwards.
            NSApp.hide(nil)
            NSApp.setActivationPolicy(policy)
            NSApp.unhideWithoutActivation()
            return
        }
        NSApp.setActivationPolicy(policy)
    }

    private static func installCloseObserverIfNeeded() {
        guard closeObserver == nil else { return }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { refresh() }
        }
    }
}
