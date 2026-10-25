import AppKit
import SwiftUI

/// Floating panel for Test EQ. `openWindow` from a `.menu` MenuBarExtra often never
/// surfaces on LSUIElement apps — this AppKit panel always appears above the menu bar.
@MainActor
final class TestEQPanelController {
    static let shared = TestEQPanelController()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let hosting = NSHostingController(
            rootView: TestEQView()
                .environmentObject(AppModel.shared)
        )
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        self.panel = panel

        panel.setContentSize(hosting.view.fittingSize)
        positionNearMenuBar(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Test EQ"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        return panel
    }

    private func positionNearMenuBar(_ panel: NSPanel) {
        let size = panel.frame.size
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            // Just under the menu bar, horizontally centered on the main display.
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
    }
}
