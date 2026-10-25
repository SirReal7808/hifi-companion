import AppKit
import SwiftUI

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController {
    static let shared = PEQPanelController()

    private var panel: NSPanel?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let hosting = NSHostingController(
            rootView: PEQView()
                .environmentObject(AppModel.shared)
        )
        hosting.sizingOptions = [.intrinsicContentSize]

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        self.panel = panel

        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        // Cap height so 10-band lists scroll inside the panel instead of overflowing the footer.
        let width = max(size.width, 560)
        let height = min(max(size.height, 520), 720)
        panel.setContentSize(NSSize(width: width, height: height))
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "EQ"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 520, height: 480)
        return panel
    }

    private func positionNearMenuBar(_ panel: NSPanel) {
        let size = panel.frame.size
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let x = visible.midX - size.width / 2
            let y = visible.maxY - size.height - 8
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
    }
}

/// Compatibility alias so older call sites keep compiling during the rename.
typealias TestEQPanelController = PEQPanelController
