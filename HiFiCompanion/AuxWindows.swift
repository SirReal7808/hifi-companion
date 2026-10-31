import AppKit
import SwiftUI

/// Settings and first-run windows. Plain AppKit windows hosting SwiftUI: the SwiftUI
/// `Settings` scene / `openWindow` are unreliable from a menu bar panel in an LSUIElement app.
@MainActor
final class AuxWindows {
    static let shared = AuxWindows()

    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func showSettings() {
        let window = settingsWindow ?? makeWindow(
            title: "HiFi Companion Settings",
            content: SettingsView().environmentObject(AppModel.shared)
        )
        settingsWindow = window
        present(window)
    }

    func showWelcome() {
        let window = welcomeWindow ?? makeWindow(
            title: "Welcome to HiFi Companion",
            content: WelcomeView().environmentObject(AppModel.shared)
        )
        welcomeWindow = window
        present(window)
    }

    func closeWelcome() {
        welcomeWindow?.close()
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Automation (`--ui-screenshots <dir>`)

    /// Captures the menu panel content, each Settings tab and the welcome window as PNGs.
    func captureForAutomation(to directory: String) async -> [String: Bool] {
        var results: [String: Bool] = [:]
        let model = AppModel.shared

        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        let host = NSHostingView(rootView: StatusMenuView().environmentObject(model))
        host.frame.size = host.fittingSize
        effect.frame = host.frame
        effect.addSubview(host)
        panel.contentView = effect
        panel.setContentSize(host.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        results["panel"] = Self.capture(panel, to: "\(directory)/menu-panel.png")
        panel.orderOut(nil)

        for tab in SettingsTab.allCases {
            let window = makeWindow(title: "HiFi Companion Settings", content: SettingsView(tab: tab).environmentObject(model))
            window.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 700_000_000)
            results["settings-\(tab.rawValue)"] = Self.capture(window, to: "\(directory)/settings-\(tab.rawValue).png")
            window.close()
        }

        let welcome = makeWindow(title: "Welcome to HiFi Companion", content: WelcomeView().environmentObject(model))
        welcome.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 500_000_000)
        results["welcome"] = Self.capture(welcome, to: "\(directory)/welcome.png")
        welcome.close()
        return results
    }

    private static func capture(_ window: NSWindow, to path: String) -> Bool {
        let wid = CGWindowID(window.windowNumber)
        guard wid != 0,
              let image = CGWindowListCreateImage(.null, [.optionIncludingWindow], wid, [.boundsIgnoreFraming, .bestResolution]),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
