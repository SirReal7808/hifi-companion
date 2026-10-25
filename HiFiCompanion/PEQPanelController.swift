import AppKit
import SwiftUI

/// Floating panel for the 10-band PEQ (MenuBarExtra `.menu` cannot host this reliably).
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

        let size = hosting.view.fittingSize
        panel.setContentSize(NSSize(width: max(size.width, 520), height: min(max(size.height, 560), 720)))
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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "PEQ"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 480, height: 420)
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
