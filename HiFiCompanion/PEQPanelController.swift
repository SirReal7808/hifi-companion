import AppKit
import SwiftUI

/// Shared EQ panel vertical metrics. List rows are forced to `rowPitch`, so
/// `fullContentHeight` matches tight layout (footer flush with content bottom).
enum PEQPanelMetrics {
    static let rowPitch: CGFloat = 36
    static let peekRows: CGFloat = 3.28
    static let padding: CGFloat = 28          // 14 + 14
    static let spacing: CGFloat = 10          // VStack spacing
    static let header: CGFloat = 28
    static let globals: CGFloat = 52
    static let graph: CGFloat = 220
    static let bottom: CGFloat = 28
    /// Gaps between header → globals → graph → list → footer.
    static let baseGapCount = 4

    static func listHeight(bandCount: Int, showAllBands: Bool) -> CGFloat {
        if bandCount <= 0 { return 8 }
        if showAllBands || bandCount <= 3 {
            return CGFloat(bandCount) * rowPitch
        }
        return peekRows * rowPitch
    }

    /// Everything except the band list (padding + fixed sections + VStack gaps).
    static var chromeHeight: CGFloat {
        padding + header + globals + graph + bottom + CGFloat(baseGapCount) * spacing
    }

    /// Compact height (1–3 full rows, 4+ peek).
    static func preferredContentHeight(bandCount: Int) -> CGFloat {
        chromeHeight + listHeight(bandCount: bandCount, showAllBands: false)
    }

    /// Tight height when all N band rows are fully visible (no list scroll, no gap under footer).
    static func fullContentHeight(bandCount: Int) -> CGFloat {
        chromeHeight + listHeight(bandCount: bandCount, showAllBands: true)
    }
}

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController: NSObject, NSWindowDelegate {
    static let shared = PEQPanelController()

    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?
    /// Optional SwiftUI-reported tight height (chrome + all rows); overrides formula when set.
    private var measuredTightContentHeight: CGFloat?

    var isVisible: Bool { panel?.isVisible == true }

    private override init() {
        super.init()
    }

    func show() {
        let root = AnyView(
            PEQView()
                .environmentObject(AppModel.shared)
        )
        let hosting = self.hosting ?? NSHostingController(rootView: root)
        hosting.rootView = root
        // Fill the panel so the band list absorbs height between graph and footer.
        hosting.sizingOptions = []
        self.hosting = hosting

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        panel.delegate = self
        self.panel = panel

        applyBandCountConstraints(reposition: !panel.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Called from SwiftUI when the tight “all bands visible” content height is measured.
    func updateMeasuredTightContentHeight(_ height: CGFloat) {
        guard height > 0 else { return }
        if let previous = measuredTightContentHeight, abs(previous - height) < 1 {
            return
        }
        measuredTightContentHeight = height
        applyBandCountConstraints(reposition: false)
    }

    /// Update max for current band count; clamp down on remove; grow only to compact preferred.
    func resizeToFitContent(reposition: Bool = false) {
        // Band-count changes invalidate a prior measurement until SwiftUI reports again.
        measuredTightContentHeight = nil
        applyBandCountConstraints(reposition: reposition)
    }

    private func applyBandCountConstraints(reposition: Bool) {
        guard let panel else { return }
        let width: CGFloat = 580
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let bandCount = AppModel.shared.peqBands.count
        let preferred = min(max(PEQPanelMetrics.preferredContentHeight(bandCount: bandCount), 420), screenMaxH)
        let formulaFull = PEQPanelMetrics.fullContentHeight(bandCount: bandCount)
        let full = min(max(measuredTightContentHeight ?? formulaFull, preferred), screenMaxH)

        applyMaxContentHeight(full, on: panel)

        let current = panel.contentLayoutRect.height
        // Add: keep height (scrollbar if needed). Remove: clamp to new max.
        // Below compact preferred: grow up to preferred only.
        let height: CGFloat
        if current > full {
            height = full
        } else if current < preferred {
            height = preferred
        } else {
            height = current
        }

        let oldFrame = panel.frame
        if abs(height - current) > 1 {
            panel.setContentSize(NSSize(width: max(width, panel.contentLayoutRect.width), height: height))
            applyMaxContentHeight(full, on: panel)
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

    private func applyMaxContentHeight(_ contentHeight: CGFloat, on panel: NSPanel) {
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: contentHeight)
        let titleChrome = max(0, panel.frame.height - panel.contentLayoutRect.height)
        panel.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: contentHeight + titleChrome
        )
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        var size = frameSize
        size.width = max(size.width, sender.minSize.width)
        size.height = min(max(size.height, sender.minSize.height), sender.maxSize.height)
        return size
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
        let initialFull = PEQPanelMetrics.fullContentHeight(bandCount: 0)
        panel.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: initialFull)
        panel.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: initialFull + 28)
        panel.delegate = self
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

typealias TestEQPanelController = PEQPanelController
