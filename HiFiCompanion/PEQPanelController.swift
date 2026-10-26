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
        // Fill the panel so the band list can expand when the user lengthens the window.
        hosting.sizingOptions = []
        self.hosting = hosting

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        self.panel = panel

        growToFitContentIfNeeded(reposition: !panel.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Grow the panel to fit preferred content. Never shrinks (keeps manual lengthening).
    func resizeToFitContent(reposition: Bool = false) {
        growToFitContentIfNeeded(reposition: reposition)
    }

    private func growToFitContentIfNeeded(reposition: Bool) {
        guard let panel else { return }
        let width: CGFloat = 720
        let maxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let preferred = min(max(Self.preferredHeight(bandCount: AppModel.shared.peqBands.count), 560), maxH)
        let current = panel.contentLayoutRect.height
        // Only grow — manual lengthening is kept so the band list can fill the extra space.
        let height = max(preferred, current)
        let oldFrame = panel.frame
        if abs(height - current) > 1 || panel.contentLayoutRect.width < width - 1 {
            panel.setContentSize(NSSize(width: max(width, panel.contentLayoutRect.width), height: height))
        }
        if reposition {
            positionNearMenuBar(panel)
        } else if let screen = panel.screen ?? NSScreen.main, abs(panel.frame.height - oldFrame.height) > 1 {
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

    /// Compact chrome + graph + side controls / min band list (1–3 full rows, 4+ peeks).
    private static func preferredHeight(bandCount: Int) -> CGFloat {
        let padding: CGFloat = 28
        let toolbar: CGFloat = 36
        let graph: CGFloat = 228
        let bottom: CGFloat = 44
        let spacing: CGFloat = 36
        let rowPitch: CGFloat = 40
        // Side column: Output / Bypass / Tone + Peak·Dip buttons (must not clip).
        let sideControls: CGFloat = 320
        let list: CGFloat
        if bandCount <= 0 {
            list = 8
        } else if bandCount <= 3 {
            list = CGFloat(bandCount) * rowPitch
        } else {
            list = 3.28 * rowPitch
        }
        let middle = max(list, sideControls)
        // Optional “Enable Pass-through first” caption above the graph.
        let disabledBanner: CGFloat = 18
        return padding + toolbar + disabledBanner + graph + spacing + middle + bottom
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
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
        panel.minSize = NSSize(width: 680, height: 480)
        panel.isOpaque = false
        panel.backgroundColor = .clear
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
