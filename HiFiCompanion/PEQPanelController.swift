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

    /// Grow toward compact preferred height; clamp to full-bands max (no empty gap).
    func resizeToFitContent(reposition: Bool = false) {
        growToFitContentIfNeeded(reposition: reposition)
    }

    private func growToFitContentIfNeeded(reposition: Bool) {
        guard let panel else { return }
        let width: CGFloat = 580
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let bandCount = AppModel.shared.peqBands.count
        let preferred = min(max(Self.preferredHeight(bandCount: bandCount), 420), screenMaxH)
        // Max height = chrome + every band row fully visible (no empty gap below last band).
        let full = min(max(Self.fullContentHeight(bandCount: bandCount), preferred), screenMaxH)
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: full)

        let current = panel.contentLayoutRect.height
        // Grow to preferred when content needs it; allow manual lengthening up to full;
        // clamp down when bands shrink so max drops below the current height.
        let height = min(max(preferred, current), full)
        let oldFrame = panel.frame
        if abs(height - current) > 1 {
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

    /// Compact chrome + graph + min band list (1–3 full rows, 4+ peeks).
    private static func preferredHeight(bandCount: Int) -> CGFloat {
        chromeHeight() + listHeight(bandCount: bandCount, showAllBands: false)
    }

    /// Chrome + graph + list tall enough for every current band row.
    private static func fullContentHeight(bandCount: Int) -> CGFloat {
        chromeHeight() + listHeight(bandCount: bandCount, showAllBands: true)
    }

    private static func chromeHeight() -> CGFloat {
        let padding: CGFloat = 28
        let headerGlobals: CGFloat = 110
        let graph: CGFloat = 220
        let bottom: CGFloat = 40
        return padding + headerGlobals + graph + bottom
    }

    private static func listHeight(bandCount: Int, showAllBands: Bool) -> CGFloat {
        let rowPitch: CGFloat = 36
        if bandCount <= 0 { return 8 }
        if showAllBands || bandCount <= 3 {
            return CGFloat(bandCount) * rowPitch
        }
        return 3.28 * rowPitch
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
        panel.contentMaxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: Self.fullContentHeight(bandCount: 0)
        )
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
