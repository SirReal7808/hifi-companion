import AppKit
import SwiftUI

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController: NSObject, NSWindowDelegate {
    static let shared = PEQPanelController()

    /// Fixed content width so band F/G/Q never clip; horizontal resize is locked.
    static let contentWidth: CGFloat = 900

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
        // Fill the panel so the band list can expand when the user lengthens the window.
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

    /// Grow to compact preferred height if needed; re-assert width lock + content max height.
    func resizeToFitContent(reposition: Bool = false) {
        applySizing(reposition: reposition)
    }

    private func applySizing(reposition: Bool) {
        guard let panel else { return }
        let width = Self.contentWidth
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let bandCount = AppModel.shared.peqBands.count
        let preferred = min(max(Self.preferredHeight(bandCount: bandCount), 560), screenMaxH)
        // Hard stop once every used band row (+ footer) is visible — no empty gap below.
        let full = min(max(Self.fullContentHeight(bandCount: bandCount), preferred), screenMaxH)

        // Prefer contentView bounds (matches `setContentSize`) over contentLayoutRect,
        // which excludes the titlebar under fullSizeContentView and would look “short”.
        let current = panel.contentView?.bounds.height ?? panel.contentLayoutRect.height
        let currentWidth = panel.contentView?.bounds.width ?? panel.contentLayoutRect.width
        // Grow to preferred when content needs it; keep manual lengthening up to `full`;
        // clamp if somehow above max (e.g. after removing bands lowers the cap).
        let height = min(max(preferred, current), full)

        let oldFrame = panel.frame
        let topY = oldFrame.maxY
        let leftX = oldFrame.origin.x

        applySizeLimits(on: panel, contentHeightMax: full, contentHeightMin: 520)

        if abs(height - current) > 1 || abs(currentWidth - width) > 1 {
            panel.setContentSize(NSSize(width: width, height: height))
            // setContentSize can drift limits on some AppKit builds — re-assert.
            applySizeLimits(on: panel, contentHeightMax: full, contentHeightMin: 520)
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
            if let screen = panel.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                if frame.maxY > visible.maxY {
                    frame.origin.y = visible.maxY - frame.height - 8
                }
                if frame.origin.y < visible.minY {
                    frame.origin.y = visible.minY + 8
                }
                // Width lock: never let frame width drift from content width + chrome.
                let chromeW = max(0, frame.width - panel.contentLayoutRect.width)
                frame.size.width = width + chromeW
            }
            panel.setFrame(frame, display: true)
            applySizeLimits(on: panel, contentHeightMax: full, contentHeightMin: 520)
        }
    }

    private func applySizeLimits(on panel: NSPanel, contentHeightMax: CGFloat, contentHeightMin: CGFloat) {
        let width = Self.contentWidth
        // Content-relative limits are the source of truth with fullSizeContentView.
        panel.contentMinSize = NSSize(width: width, height: contentHeightMin)
        panel.contentMaxSize = NSSize(width: width, height: contentHeightMax)
        let titleChrome = max(0, panel.frame.height - panel.contentLayoutRect.height)
        let widthChrome = max(0, panel.frame.width - panel.contentLayoutRect.width)
        panel.minSize = NSSize(width: width + widthChrome, height: contentHeightMin + titleChrome)
        panel.maxSize = NSSize(width: width + widthChrome, height: contentHeightMax + titleChrome)
    }

    /// Compact chrome + graph + side controls / min band list (1–3 full rows, 4+ peeks).
    private static func preferredHeight(bandCount: Int) -> CGFloat {
        chromeHeight(bandCount: bandCount) + middleHeight(bandCount: bandCount, showAllBands: false)
    }

    /// Chrome + middle tall enough for every current band row (and side column).
    private static func fullContentHeight(bandCount: Int) -> CGFloat {
        chromeHeight(bandCount: bandCount) + middleHeight(bandCount: bandCount, showAllBands: true)
    }

    private static func chromeHeight(bandCount: Int) -> CGFloat {
        let padding: CGFloat = 28
        let toolbar: CGFloat = 58
        let graph: CGFloat = 228
        let bottom: CGFloat = 44
        let spacing: CGFloat = 36 // ~3×12 VStack gaps around graph/middle/footer
        // Optional “Enable Pass-through first” caption above the graph.
        let disabledBanner: CGFloat = 18
        _ = bandCount
        return padding + toolbar + disabledBanner + graph + spacing + bottom
    }

    private static func middleHeight(bandCount: Int, showAllBands: Bool) -> CGFloat {
        let rowPitch: CGFloat = 40
        let sideControls: CGFloat = 320
        let list: CGFloat
        if bandCount <= 0 {
            list = 8
        } else if showAllBands || bandCount <= 3 {
            list = CGFloat(bandCount) * rowPitch
        } else {
            list = 3.28 * rowPitch
        }
        return max(list, sideControls)
    }

    private func makePanel() -> NSPanel {
        let width = Self.contentWidth
        // Normal titled panel (not `.utilityWindow`) so traffic lights are standard size.
        // `fullSizeContentView` + transparent titlebar → Music-like chrome; content draws under it.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
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
        let initialFull = Self.fullContentHeight(bandCount: 0)
        applySizeLimits(on: panel, contentHeightMax: initialFull, contentHeightMin: 520)
        // Opaque system background — no hollow wallpaper strip in the titlebar.
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.toolbarStyle = .unified
        return panel
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        var size = frameSize
        // Absolute horizontal lock.
        size.width = sender.minSize.width
        size.height = min(max(size.height, sender.minSize.height), sender.maxSize.height)
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
