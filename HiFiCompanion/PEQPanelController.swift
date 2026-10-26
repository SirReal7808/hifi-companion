import AppKit
import SwiftUI

/// Shared EQ panel vertical metrics — must stay in sync with `PEQView` chrome / band rows.
enum PEQPanelMetrics {
    static let contentWidth: CGFloat = 900
    /// Forced band-row height (matches `.frame(height:)` on each row).
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 8
    static let listVerticalPadding: CGFloat = 4
    /// Right-hand Output / Bypass / Tone column floor.
    static let sideControlsHeight: CGFloat = 320
    /// Shortest allowed window matches the 4-band compact screenshot.
    static let minBandCountFloor = 4

    static func listHeight(bandCount: Int) -> CGFloat {
        if bandCount <= 0 { return 8 }
        let n = CGFloat(bandCount)
        return n * rowHeight + CGFloat(bandCount - 1) * rowSpacing + listVerticalPadding
    }

    static func middleHeight(bandCount: Int) -> CGFloat {
        max(listHeight(bandCount: bandCount), sideControlsHeight)
    }

    /// Toolbar + graph + footer + paddings/gaps (banners omitted — rare while EQ is used).
    static var chromeHeight: CGFloat {
        let topPad: CGFloat = 2
        let bottomPad: CGFloat = 14
        let toolbar: CGFloat = 58
        let graph: CGFloat = 228
        let footer: CGFloat = 34
        let gaps: CGFloat = 36 // 3×12 between toolbar / graph / middle / footer
        return topPad + toolbar + graph + footer + bottomPad + gaps
    }

    /// Content height that exactly fits chrome + N band rows + footer (tight bottom padding).
    static func contentHeight(bandCount: Int) -> CGFloat {
        chromeHeight + middleHeight(bandCount: max(0, bandCount))
    }

    static var minContentHeight: CGFloat {
        contentHeight(bandCount: minBandCountFloor)
    }

    /// Never below the 4-band floor (N < 4 keeps empty space / unused slots).
    static func maxContentHeight(bandCount: Int) -> CGFloat {
        max(contentHeight(bandCount: bandCount), minContentHeight)
    }
}

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController: NSObject, NSWindowDelegate {
    static let shared = PEQPanelController()

    /// Fixed content width so band F/G/Q never clip; horizontal resize is locked.
    static let contentWidth: CGFloat = PEQPanelMetrics.contentWidth

    private var panel: NSPanel?
    private var hosting: NSHostingController<AnyView>?

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
        // Fill the panel so the band list can expand between min and max height.
        hosting.sizingOptions = []
        self.hosting = hosting

        let panel = self.panel ?? makePanel()
        panel.contentViewController = hosting
        panel.delegate = self
        self.panel = panel

        applySizing(reposition: !panel.isVisible)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Grow to the 4-band floor if needed; re-assert width lock + H(N) max height.
    func resizeToFitContent(reposition: Bool = false) {
        applySizing(reposition: reposition)
    }

    private func applySizing(reposition: Bool) {
        guard let panel else { return }
        let width = Self.contentWidth
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let bandCount = AppModel.shared.peqBands.count

        // ScrollView list: min = H(4), max = H(N) (and H(N) ≥ H(4) when N < 4).
        let idealMin = PEQPanelMetrics.minContentHeight
        let idealMax = PEQPanelMetrics.maxContentHeight(bandCount: bandCount)
        let contentMaxH = min(max(idealMax, idealMin), screenMaxH)
        let contentMinH = min(idealMin, contentMaxH)

        // Prefer contentView bounds (matches `setContentSize`) over contentLayoutRect,
        // which excludes the titlebar under fullSizeContentView and would look “short”.
        let current = panel.contentView?.bounds.height ?? panel.contentLayoutRect.height
        let currentWidth = panel.contentView?.bounds.width ?? panel.contentLayoutRect.width
        // Floor at H(4); keep manual lengthening up to H(N); clamp when remove lowers max.
        let preferred = contentMinH
        let height = min(max(preferred, current), contentMaxH)

        let oldFrame = panel.frame
        let topY = oldFrame.maxY
        let leftX = oldFrame.origin.x

        applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)

        if abs(height - current) > 1 || abs(currentWidth - width) > 1 {
            panel.setContentSize(NSSize(width: width, height: height))
            // setContentSize can drift limits on some AppKit builds — re-assert.
            applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
        }

        if reposition {
            positionNearMenuBar(panel)
        } else if abs(panel.frame.height - oldFrame.height) > 0.5
                    || abs(panel.frame.origin.x - leftX) > 0.5
                    || abs(panel.frame.maxY - topY) > 0.5 {
            // Keep top-left fixed: grow/shrink downward only (never jump upward on + Band).
            var frame = panel.frame
            frame.origin.x = leftX
            frame.origin.y = topY - frame.height
            // Keep width locked at content width (limits are frame-equivalent).
            frame.size.width = width
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if frame.maxY > visible.maxY {
                    frame.origin.y = visible.maxY - frame.height - 8
                }
                if frame.origin.y < visible.minY {
                    frame.origin.y = visible.minY + 8
                }
            }
            // Never apply an empty frame (AppKit may close the window).
            if frame.size.width >= 1, frame.size.height >= 1 {
                panel.setFrame(frame, display: true)
            }
            applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
        }
    }

    private func applySizeLimits(on panel: NSPanel, contentHeightMax: CGFloat, contentHeightMin: CGFloat) {
        let width = Self.contentWidth
        // Never allow max < min — AppKit can collapse/close the window.
        let minH = max(contentHeightMin, 1)
        let maxH = max(contentHeightMax, minH)
        // Lock width via equal min/max. Do **not** derive chrome from
        // `contentLayoutRect` (often 0 before layout → minHeight >> maxHeight → close).
        // Under fullSizeContentView, content size ≈ frame size for these limits.
        let sizeMin = NSSize(width: width, height: minH)
        let sizeMax = NSSize(width: width, height: maxH)
        panel.minSize = sizeMin
        panel.maxSize = sizeMax
        panel.contentMinSize = sizeMin
        panel.contentMaxSize = sizeMax
    }

    private func makePanel() -> NSPanel {
        let width = Self.contentWidth
        let minH = PEQPanelMetrics.minContentHeight
        // Normal titled panel (not `.utilityWindow`) so traffic lights are standard size.
        // `fullSizeContentView` + transparent titlebar → Music-like chrome; content draws under it.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: minH),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        applySizeLimits(on: panel, contentHeightMax: minH, contentHeightMin: minH)
        // Opaque system background — no hollow wallpaper strip in the titlebar.
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.toolbarStyle = .unified
        return panel
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        // Fallbacks if limits were cleared/unset — never return zero/negative.
        let minW = sender.minSize.width > 1 ? sender.minSize.width : Self.contentWidth
        let minH = sender.minSize.height > 1 ? sender.minSize.height : PEQPanelMetrics.minContentHeight
        let maxH = max(sender.maxSize.height > 1 ? sender.maxSize.height : minH, minH)
        var size = frameSize
        // Absolute horizontal lock.
        size.width = minW
        size.height = min(max(size.height, minH), maxH)
        if !size.width.isFinite || size.width < 1 { size.width = Self.contentWidth }
        if !size.height.isFinite || size.height < 1 { size.height = minH }
        return size
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
