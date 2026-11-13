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
        let window = settingsWindow ?? makeSettingsWindow(selected: .general)
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

    /// Settings is open and not hidden behind other windows.
    var isSettingsVisible: Bool {
        guard let window = settingsWindow else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    /// Settings or Welcome is on screen (keeps the app in ⌘Tab, see `DockPresence`).
    var hasOpenWindow: Bool {
        settingsWindow?.isVisible == true || welcomeWindow?.isVisible == true
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

    private func makeSettingsWindow(selected: SettingsTab) -> NSWindow {
        let window = NSWindow(contentViewController: SettingsTab.makeTabViewController(model: AppModel.shared, selected: selected))
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        AppModel.shared.appearancePreference.apply(to: window)
        DockPresence.windowWillShow()
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
            let window = makeSettingsWindow(selected: tab)
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

        // EQ window with demo bands and live-looking controls (no bridge), then Bypass EQ on.
        // `model.peq` writes to a throwaway defaults suite in this mode (AppModel.documentDefaults).
        let demo: [(EQFilterType, Double, Double, Double)] = [
            (.lowShelf, 80, 2, 0.7), (.peaking, 130, -4, 4), (.peaking, 430, 2, 0.9), (.peaking, 5_200, -3, 3.5)
        ]
        for (type, hz, gain, q) in demo {
            guard let id = model.peq.addBand() else { break }
            model.peq.updateBand(id: id) { band in
                band.filterType = type
                band.frequencyHz = hz
                band.gainDB = gain
                band.q = q
            }
        }
        model.unlockEQControlsForTesting()
        model.showPEQPanel()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        print("EQ_SIZE: \(PEQPanelController.shared.testSizingSummaryForAutomation())")
        if let eq = PEQPanelController.shared.windowForAutomation {
            results["eq"] = Self.capture(eq, to: "\(directory)/eq.png")
            let wasBypassed = model.peq.bypass
            model.peq.setBypass(true)
            try? await Task.sleep(nanoseconds: 400_000_000)
            results["eq-bypass"] = Self.capture(eq, to: "\(directory)/eq-bypass.png")
            model.peq.setBypass(wasBypassed)

            // Clipping warning (Auto Gain off, Output pushed up) with a parked sweep needle.
            model.peq.setAutoOutputGain(false)
            model.peq.setOutputGainDB(1.5)
            model.peq.setSweepNeedle(hz: 12_000)
            try? await Task.sleep(nanoseconds: 400_000_000)
            results["eq-clipping"] = Self.capture(eq, to: "\(directory)/eq-clipping.png")
        } else {
            results["eq"] = false
        }
        UserDefaults.standard.removePersistentDomain(forName: AppModel.uiScreenshotDefaultsSuite)
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
