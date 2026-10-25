import AppKit
import SwiftUI

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController {
    static let shared = PEQPanelController()

    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?

    var isVisible: Bool { panel?.isVisible == true }

    func show() {
        let root = AnyView(
            PEQView()
                .environmentObject(AppModel.shared)
        )
        let hosting = self.hosting ?? NSHostingController(rootView: root)
        hosting.rootView = root
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        self.panel = panel

        resizeToFitContent(reposition: panel.frame.origin == .zero || !panel.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Grow/shrink the floating panel to the SwiftUI fitting size (capped).
    func resizeToFitContent(reposition: Bool = false) {
        guard let panel, let hosting else { return }
        hosting.view.invalidateIntrinsicContentSize()
        hosting.view.layoutSubtreeIfNeeded()
        let size = hosting.view.fittingSize
        let width = max(size.width, 580)
        // Allow short (few bands) and taller (scroll region) without exceeding the screen.
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let height = min(max(size.height, 420), maxH)
        let oldFrame = panel.frame
        panel.setContentSize(NSSize(width: width, height: height))
        if reposition {
            positionNearMenuBar(panel)
        } else if let screen = panel.screen ?? NSScreen.main {
            // Keep top edge stable when height changes (grow downward).
            var frame = panel.frame
            let delta = frame.height - oldFrame.height
            frame.origin.y -= delta
            let visible = screen.visibleFrame
            if frame.maxY > visible.maxY {
                frame.origin.y = visible.maxY - frame.height - 8
            }
            if frame.origin.y < visible.minY {
                frame.origin.y = visible.minY + 8
            }
            panel.setFrame(frame, display: true)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
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
        panel.minSize = NSSize(width: 540, height: 400)
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
