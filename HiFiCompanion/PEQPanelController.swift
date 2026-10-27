import AppKit
import SwiftUI
import os.log

private let peqPanelLog = Logger(subsystem: "HiFiCompanion", category: "PEQPanel")

/// Shared EQ panel vertical metrics — must stay in sync with `PEQView` chrome / band rows.
///
/// Policy (locked): width fixed; height is exact `H(N)` with `min == max`; the user cannot
/// drag or zoom. Add/remove band grows/shrinks from the top-left. For `N < 4`, height stays
/// at the 4-band layout so the side column / Reset never collapse.
enum PEQPanelMetrics {
    static let contentWidth: CGFloat = 900
    /// Forced band-row height (matches `.frame(height:)` on each row).
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 8
    static let listVerticalPadding: CGFloat = 4
    /// Intrinsic height of the Output / Bypass / Tone / Peak-Dip glass stack.
    /// Live PreferenceKey probes were abandoned — they read the proposed middle height
    /// and inflated `H(N)` into a void under Add Band / Reset.
    static let sideControlsHeight: CGFloat = 372
    /// Shortest window matches the 4-band compact layout.
    static let minBandCountFloor = 4

    static func listHeight(bandCount: Int) -> CGFloat {
        if bandCount <= 0 { return 8 }
        let n = CGFloat(bandCount)
        return n * rowHeight + CGFloat(bandCount - 1) * rowSpacing + listVerticalPadding
    }

    /// Toolbar + graph + footer + paddings/gaps (banners omitted — rare while EQ is used).
    static var chromeHeight: CGFloat {
        let topPad: CGFloat = 2
        let bottomPad: CGFloat = 4
        // toolbarRow: minHeight 52 + padding.top 6
        let toolbar: CGFloat = 58
        let graph: CGFloat = 228
        let footer: CGFloat = 28
        let gaps: CGFloat = 36 // 3×12 between toolbar / graph / middle / footer
        return topPad + toolbar + graph + footer + bottomPad + gaps
    }

    /// Middle band/side region: `max(list(N), side)`, never shorter than the 4-band list.
    static func middleRegionHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        let side = sideHeight.isFinite && sideHeight > 0 ? sideHeight : sideControlsHeight
        let list = listHeight(bandCount: max(0, bandCount))
        let floor = listHeight(bandCount: minBandCountFloor)
        return max(list, floor, side)
    }

    /// Exact content height for N bands (`min == max` callers).
    static func contentHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        chromeHeight + middleRegionHeight(bandCount: max(0, bandCount), sideHeight: sideHeight)
    }

    /// Fixed content height for a band count. Always `min == max >= 1`.
    static func contentHeightLimits(
        bandCount: Int,
        sideHeight: CGFloat = sideControlsHeight,
        screenMaxH: CGFloat
    ) -> (min: CGFloat, max: CGFloat) {
        let ideal = contentHeight(bandCount: bandCount, sideHeight: sideHeight)
        let screenCap = max(screenMaxH.isFinite ? screenMaxH : ideal, 1)
        let h = max(min(ideal, screenCap), 1)
        return (h, h)
    }
}

/// NSPanel that refuses any frame/content size other than the controller's locked H(N).
/// NSHostingView periodically re-expands fullSizeContentView panels by ~32pt (titlebar
/// safe-area); clamping here is the only reliable counter without fighting min==max.
private final class ExactHeightEQPanel: NSPanel {
    /// When set, every setFrame / setContentSize is forced to this size (top-left preserved).
    var lockedContentSize: NSSize?

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let locked = lockedContentSize {
            let topY = frameRect.maxY
            rect.size.width = locked.width
            rect.size.height = locked.height
            rect.origin.y = topY - locked.height
            rect.origin.x = frameRect.origin.x
        }
        super.setFrame(rect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        // Never animate EQ size — animated hosting updates crash AppKit constraints.
        setFrame(frameRect, display: flag)
    }

    override func setContentSize(_ size: NSSize) {
        if let locked = lockedContentSize {
            super.setContentSize(locked)
        } else {
            super.setContentSize(size)
        }
    }
}

/// Floating EQ panel (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController: NSObject, NSWindowDelegate {
    static let shared = PEQPanelController()

    /// Fixed content width so band F/G/Q never clip; horizontal resize is locked.
    static let contentWidth: CGFloat = PEQPanelMetrics.contentWidth

    private var panel: ExactHeightEQPanel?
    private var hosting: NSHostingController<AnyView>?
    /// Cached height — used only to skip redundant setFrame when already fitted.
    private var lockedContentHeight: CGFloat = PEQPanelMetrics.contentHeight(bandCount: PEQPanelMetrics.minBandCountFloor)
    /// Prevents `windowDidResize` ↔ `applySizing` re-entry.
    private var isApplyingSize = false
    private var pendingSizePass = false
    private var pendingVerifyWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible == true }

    /// Test hook — NSWindow.frame height (excludes CG shadow).
    func testFrameHeightForAutomation() -> CGFloat {
        let h = panel?.frame.height ?? 0
        return h.isFinite ? h : 0
    }

    /// Test hook — dump sizing for automation logs.
    func testSizingSummaryForAutomation() -> String {
        guard let panel else { return "nil" }
        func i(_ v: CGFloat) -> Int {
            guard v.isFinite, v > -1_000_000, v < 1_000_000 else { return -1 }
            return Int(v.rounded())
        }
        let cv = panel.contentView?.bounds.height ?? -1
        let zoom = panel.standardWindowButton(.zoomButton)
        let zoomHidden = zoom?.isHidden ?? true
        let zoomEnabled = zoom?.isEnabled ?? false
        return "frame=\(i(panel.frame.height)) content=\(i(cv)) min=\(i(panel.minSize.height)) max=\(i(panel.maxSize.height)) locked=\(i(lockedContentHeight)) zoomHidden=\(zoomHidden) zoomEnabled=\(zoomEnabled)"
    }

    /// Test hook — capture the EQ panel window to JPEG (own-process, no Screen Recording TCC).
    @discardableResult
    func testCapturePNG(to path: String) -> Bool {
        guard let panel else { return false }
        panel.layoutIfNeeded()
        let wid = CGWindowID(panel.windowNumber)
        guard wid != 0 else { return false }
        let opts: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        guard let cgImage = CGWindowListCreateImage(
            .null,
            [.optionIncludingWindow],
            wid,
            opts
        ) else { return false }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            return false
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            return false
        }
    }

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
        // Never let SwiftUI drive NSWindow size — that path adds titlebar-safe-area
        // (~32pt) on top of our exact H(N) and opens the void under Add Band / Reset.
        hosting.sizingOptions = []
        if #available(macOS 14.0, *) {
            hosting.safeAreaRegions = []
        }
        self.hosting = hosting

        // Always recreate — a reused NSPanel kept titlebar chrome that let the
        // hosting view inflate height by ~32pt (void under Add Band / Reset).
        if let existing = panel {
            existing.orderOut(nil)
            existing.delegate = nil
            existing.contentViewController = nil
            existing.lockedContentSize = nil
            self.panel = nil
        }

        let panel = makePanel()
        panel.contentViewController = hosting
        panel.delegate = self
        panel.animationBehavior = .none
        configureChrome(on: panel)
        self.panel = panel

        applySizing(reposition: true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        configureChrome(on: panel)
        scheduleVerifyPasses()
    }

    func close() {
        pendingVerifyWork?.cancel()
        pendingVerifyWork = nil
        panel?.lockedContentSize = nil
        panel?.orderOut(nil)
    }

    /// Snap to fixed H(N) for the current band count.
    func resizeToFitContent(reposition: Bool = false) {
        applySizing(reposition: reposition)
        scheduleVerifyPasses()
    }

    private func scheduleVerifyPasses() {
        pendingVerifyWork?.cancel()
        // Hosting often re-expands one runloop after band add/remove; ExactHeightEQPanel
        // clamps, and these passes refresh lockedContentSize after SwiftUI settles.
        let delays: [TimeInterval] = [0.0, 0.05, 0.15, 0.35, 0.6]
        var last: DispatchWorkItem?
        for delay in delays {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.applySizing(reposition: false)
                if let panel = self.panel { self.configureChrome(on: panel) }
            }
            last = work
            if delay == 0 {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }
        pendingVerifyWork = last
    }

    private func applySizing(reposition: Bool) {
        guard let panel else { return }
        if isApplyingSize {
            pendingSizePass = true
            return
        }
        isApplyingSize = true
        defer {
            isApplyingSize = false
            if pendingSizePass {
                pendingSizePass = false
                DispatchQueue.main.async { [weak self] in
                    self?.applySizing(reposition: false)
                }
            }
        }

        let width = Self.contentWidth
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let bandCount = AppModel.shared.peqBands.count
        let limits = PEQPanelMetrics.contentHeightLimits(
            bandCount: bandCount,
            screenMaxH: screenMaxH
        )
        let targetH = max(limits.min, 1)
        lockedContentHeight = targetH

        let oldFrame = panel.frame
        let topY = oldFrame.maxY
        let leftX = oldFrame.origin.x

        var origin = CGPoint(x: leftX, y: topY - targetH)
        if reposition {
            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                origin.x = visible.midX - width / 2
                origin.y = visible.maxY - targetH - 8
            }
        } else if let screen = panel.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y + targetH > visible.maxY {
                origin.y = visible.maxY - targetH - 8
            }
            if origin.y < visible.minY {
                origin.y = visible.minY + 8
            }
        }

        let locked = NSSize(width: width, height: targetH)
        // Lock BEFORE setFrame so any nested AppKit/hosting setFrame is clamped.
        panel.lockedContentSize = locked

        let targetFrame = NSRect(x: origin.x, y: origin.y, width: width, height: targetH)
        let alreadyFitted = abs(oldFrame.height - targetH) <= 0.5
            && abs(oldFrame.width - width) <= 0.5
            && abs(oldFrame.origin.x - origin.x) <= 0.5
            && abs(oldFrame.origin.y - origin.y) <= 0.5
        if alreadyFitted && !reposition {
            return
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            panel.setFrame(targetFrame, display: true)
            if let cv = panel.contentView {
                cv.setFrameSize(locked)
            }
            if let hv = hosting?.view {
                hv.setFrameSize(locked)
            }
        }

        peqPanelLog.debug(
            "EQ size bands=\(bandCount) H=\(targetH, format: .fixed(precision: 0)) frame=\(panel.frame.height, format: .fixed(precision: 0))"
        )
    }

    private func configureChrome(on panel: NSPanel) {
        panel.animationBehavior = .none
        // Green traffic light must not zoom / fullscreen this panel.
        if let zoom = panel.standardWindowButton(.zoomButton) {
            zoom.isHidden = true
            zoom.isEnabled = false
            zoom.alphaValue = 0
            zoom.isTransparent = true
            zoom.setFrameSize(.zero)
        }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
    }

    private func makePanel() -> ExactHeightEQPanel {
        let width = Self.contentWidth
        let minH = PEQPanelMetrics.contentHeight(bandCount: PEQPanelMetrics.minBandCountFloor)
        // Not `.resizable` — height is exact H(N); green zoom and edge-drag are disabled.
        let panel = ExactHeightEQPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: minH),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.animationBehavior = .none
        panel.delegate = self
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.lockedContentSize = NSSize(width: width, height: minH)
        panel.setFrame(NSRect(x: 0, y: 0, width: width, height: minH), display: false)
        configureChrome(on: panel)
        return panel
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        let h = lockedContentHeight > 1
            ? lockedContentHeight
            : PEQPanelMetrics.contentHeight(bandCount: AppModel.shared.peqBands.count)
        return NSSize(width: Self.contentWidth, height: h)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, (notification.object as? NSWindow) === panel else { return }
        guard !isApplyingSize else { return }
        let targetH = lockedContentHeight
        guard targetH > 1, abs(panel.frame.height - targetH) > 0.5 else { return }
        // Hosting slipped past the lock (should be rare with ExactHeightEQPanel).
        DispatchQueue.main.async { [weak self] in
            self?.applySizing(reposition: false)
        }
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        window === panel ? false : true
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        guard window === panel else { return newFrame }
        return window.frame
    }
}

/// Compatibility alias so older call sites keep compiling during the rename.
typealias TestEQPanelController = PEQPanelController
