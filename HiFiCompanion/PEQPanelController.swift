import AppKit
import SwiftUI
import os.log

private let peqPanelLog = Logger(subsystem: "HiFiCompanion", category: "PEQPanel")

/// Shared EQ panel vertical metrics — must stay in sync with `PEQView` chrome / band rows.
///
/// Policy: width fixed; height is exact `H(N)` with `min == max`. Middle hugs
/// `max(list, side)` (no extra void). On short screens, graph shrinks first so
/// titlebar + footer stay inside `visibleFrame`.
enum PEQPanelMetrics {
    static let contentWidth: CGFloat = 900
    /// Forced band-row height (matches `.frame(height:)` on each row).
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 8
    static let listVerticalPadding: CGFloat = 4
    /// Fallback side stack height until SwiftUI reports the intrinsic measure.
    /// Keep close to the real glass — oversized constants left a void under bands.
    static let sideControlsHeight: CGFloat = 360
    /// Live intrinsic side height from `PEQView` (0 = use fallback).
    static var measuredSideHeight: CGFloat = 0

    static var effectiveSideHeight: CGFloat {
        measuredSideHeight > 40 ? measuredSideHeight : sideControlsHeight
    }
    /// Middle uses `.compositingGroup().clipped()` so the side shadow does not
    /// paint the footer — only a few points of air under the glass.
    static let sideShadowBleed: CGFloat = 4
    /// Air between middle and the footer strip.
    static let footerClearance: CGFloat = 10
    /// Equal inset above/below Add Band / Reset inside the footer.
    static let footerChipInset: CGFloat = 8
    /// Chip ≈ 31pt (7+7 pad + label); strip = chip + 2×inset.
    static let footerHeight: CGFloat = 47
    /// Shortest window matches the 4-band compact layout.
    static let minBandCountFloor = 4

    static let graphHeightIdeal: CGFloat = 228
    static let graphHeightMin: CGFloat = 140
    /// Margin inside `NSScreen.visibleFrame` (menu bar / Dock already excluded).
    static let screenEdgeMargin: CGFloat = 16

    /// Last screen cap applied by the panel controller (PEQView reads this).
    static var activeScreenMaxH: CGFloat = 2_000

    struct Layout: Equatable {
        var graphHeight: CGFloat
        var middleHeight: CGFloat
        var contentHeight: CGFloat
    }

    static func listHeight(bandCount: Int) -> CGFloat {
        if bandCount <= 0 { return 8 }
        let n = CGFloat(bandCount)
        return n * rowHeight + CGFloat(bandCount - 1) * rowSpacing + listVerticalPadding
    }

    /// Chrome excluding the graph (toolbar / gaps / footer / pads).
    static var chromeExcludingGraph: CGFloat {
        let topPad: CGFloat = 2
        let bottomPad = footerChipInset
        let toolbar: CGFloat = 58
        let footer = footerHeight
        // 3×12 between toolbar / graph / middle / footer, plus clearance above footer.
        let gaps: CGFloat = 36 + footerClearance
        return topPad + toolbar + footer + bottomPad + gaps
    }

    /// Toolbar + ideal graph + footer + paddings/gaps.
    static var chromeHeight: CGFloat { chromeExcludingGraph + graphHeightIdeal }

    static func middleRegionHeight(bandCount: Int, sideHeight: CGFloat = 0) -> CGFloat {
        layout(bandCount: bandCount, screenMaxH: activeScreenMaxH, sideHeight: sideHeight).middleHeight
    }

    static func contentHeight(bandCount: Int, sideHeight: CGFloat = 0) -> CGFloat {
        layout(bandCount: bandCount, screenMaxH: activeScreenMaxH, sideHeight: sideHeight).contentHeight
    }

    /// Resolve caller side height: explicit >40 wins; else live measure / fallback.
    static func resolvedSideHeight(_ sideHeight: CGFloat) -> CGFloat {
        if sideHeight.isFinite, sideHeight > 40 { return sideHeight }
        return effectiveSideHeight
    }

    /// Ideal middle: `max(list, 4-band floor, side+shadow)` — no extra inflation.
    static func idealMiddleHeight(bandCount: Int, sideHeight: CGFloat = 0) -> CGFloat {
        let side = resolvedSideHeight(sideHeight)
        let list = listHeight(bandCount: max(0, bandCount))
        let floor = listHeight(bandCount: minBandCountFloor)
        return max(list, floor, side + sideShadowBleed)
    }

    /// Fit `H(N)` into `screenMaxH`: shrink graph first, then middle (band list scrolls).
    /// Pass `sideHeight` 0 (default) to use `effectiveSideHeight` (live measure).
    static func layout(
        bandCount: Int,
        screenMaxH: CGFloat,
        sideHeight: CGFloat = 0
    ) -> Layout {
        let sideBase = resolvedSideHeight(sideHeight)
        let sideMid = sideBase + sideShadowBleed
        let listFloor = max(
            listHeight(bandCount: max(0, bandCount)),
            listHeight(bandCount: minBandCountFloor)
        )
        var middle = max(listFloor, sideMid)
        var graph = graphHeightIdeal
        let chrome = chromeExcludingGraph
        var total = chrome + graph + middle

        let cap = max(screenMaxH.isFinite ? screenMaxH : total, 320)
        if total <= cap {
            return Layout(graphHeight: graph, middleHeight: middle, contentHeight: total)
        }

        // 1) Shrink graph toward min.
        let graphCut = min(total - cap, graph - graphHeightMin)
        graph -= max(0, graphCut)
        total = chrome + graph + middle
        if total <= cap {
            return Layout(graphHeight: graph, middleHeight: middle, contentHeight: total)
        }

        // 2) Shrink middle, but keep ≥ side+bleed when possible (don't clip the glass).
        let need = total - cap
        if middle - need >= sideMid {
            middle -= need
            return Layout(graphHeight: graph, middleHeight: middle, contentHeight: cap)
        }

        // 3) Still too tall: keep side visible, pin to cap (graph already at min).
        middle = max(sideMid, cap - chrome - graph)
        graph = max(graphHeightMin, min(graph, cap - chrome - middle))
        total = min(cap, chrome + graph + middle)
        return Layout(graphHeight: graph, middleHeight: middle, contentHeight: max(total, 1))
    }

    /// Fixed content height for a band count. Always `min == max >= 1`.
    static func contentHeightLimits(
        bandCount: Int,
        sideHeight: CGFloat = 0,
        screenMaxH: CGFloat
    ) -> (min: CGFloat, max: CGFloat) {
        let h = layout(bandCount: bandCount, screenMaxH: screenMaxH, sideHeight: sideHeight).contentHeight
        return (h, h)
    }

    /// Usable height on a screen: `visibleFrame` minus a small edge margin.
    static func usableHeight(on screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.height ?? 900
        return max(visible - screenEdgeMargin, 320)
    }
}

/// Normal `NSWindow` that refuses any frame/content size other than the controller's locked H(N).
///
/// `NSHostingView` on `fullSizeContentView` windows repeatedly asks for +~32pt. Calling
/// `super.setFrame` on every hostile request re-enters layout and pegs a CPU core — so
/// when we are already at the locked size we no-op instead of clamping-via-super.
/// Not an `NSPanel` / floating utility — other apps must be able to cover it.
private final class ExactHeightEQPanel: NSWindow {
    /// When set, every setFrame / setContentSize is forced to this size (top-left preserved).
    var lockedContentSize: NSSize?

    /// Standard titled-window traffic-light insets (Finder/Cursor). Constants only —
    /// never probe by constructing/closing a temporary `NSWindow` (that over-released
    /// under ARC when `isReleasedWhenClosed` defaulted to true → launch SIGSEGV).
    private static let closeInsetLeading: CGFloat = 7
    private static let closeInsetTop: CGFloat = 6

    /// Keep mini/zoom layout slots (alpha only — never `setFrameSize(.zero)` / layout-collapsing
    /// `isHidden`). Optionally nudge close if AppKit packed it into the corner.
    func alignTrafficLights() {
        for kind in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind) else { continue }
            button.isHidden = false
            button.alphaValue = 0
            button.isEnabled = false
        }
        guard let close = standardWindowButton(.closeButton),
              let closeSuper = close.superview else { return }
        let size = close.frame.size
        guard size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1,
              frame.height.isFinite, frame.height > 1 else { return }

        // Window-coordinate origin for a normal titled close control.
        let originInWindow = NSPoint(
            x: Self.closeInsetLeading,
            y: frame.height - Self.closeInsetTop - size.height
        )
        guard originInWindow.x.isFinite, originInWindow.y.isFinite else { return }
        let originInSuper = closeSuper.convert(originInWindow, from: nil)
        guard originInSuper.x.isFinite, originInSuper.y.isFinite else { return }

        // Only correct clearly packed-into-corner frames; leave healthy AppKit layout alone.
        let frameInWindow = closeSuper.convert(close.frame, to: nil)
        let leading = frameInWindow.minX
        let top = frame.height - frameInWindow.maxY
        let packed = leading < 4 || top < 3
        if packed,
           (abs(close.frame.origin.x - originInSuper.x) > 0.5
            || abs(close.frame.origin.y - originInSuper.y) > 0.5) {
            close.setFrameOrigin(originInSuper)
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        guard let locked = lockedContentSize else {
            super.setFrame(frameRect, display: flag)
            return
        }

        let current = frame
        let alreadyLocked =
            abs(current.width - locked.width) <= 0.5
            && abs(current.height - locked.height) <= 0.5

        // Hostile resize while already correct — drop it. Re-entering super.setFrame here
        // is what spun ~100%+ CPU after open on fullSizeContentView + hosting.
        if alreadyLocked,
           abs(frameRect.width - locked.width) > 0.5
            || abs(frameRect.height - locked.height) > 0.5 {
            return
        }

        var rect = frameRect
        rect.size.width = locked.width
        rect.size.height = locked.height
        // Grow/shrink from top-left: keep the requested top edge when possible.
        rect.origin.y = frameRect.maxY - locked.height
        rect.origin.x = frameRect.origin.x

        if alreadyLocked,
           abs(current.origin.x - rect.origin.x) <= 0.5,
           abs(current.origin.y - rect.origin.y) <= 0.5 {
            return
        }

        super.setFrame(rect, display: flag)
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animateFlag: Bool) {
        // Never animate EQ size — animated hosting updates crash AppKit constraints.
        setFrame(frameRect, display: flag)
    }

    override func setContentSize(_ size: NSSize) {
        if let locked = lockedContentSize {
            let current = contentView?.bounds.size ?? .zero
            if abs(current.width - locked.width) <= 0.5,
               abs(current.height - locked.height) <= 0.5,
               (abs(size.width - locked.width) > 0.5 || abs(size.height - locked.height) > 0.5) {
                return
            }
            if abs(current.width - locked.width) <= 0.5,
               abs(current.height - locked.height) <= 0.5 {
                return
            }
            super.setContentSize(locked)
        } else {
            super.setContentSize(size)
        }
    }
}

/// EQ window opened from the menu extra (MenuBarExtra `.menu` cannot host this reliably).
@MainActor
final class PEQPanelController: NSObject, NSWindowDelegate {
    static let shared = PEQPanelController()

    /// Fixed content width so band F/G/Q never clip; horizontal resize is locked.
    static let contentWidth: CGFloat = PEQPanelMetrics.contentWidth

    /// Stamp so automation / Console can confirm which binary is running.
    static let buildStamp = "eq-fit-laptop-v3"

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
        let mini = panel.standardWindowButton(.miniaturizeButton)
        let close = panel.standardWindowButton(.closeButton)
        let closeOrigin = close.map { "\(i($0.frame.origin.x)),\(i($0.frame.origin.y))" } ?? "-"
        let miniAlpha = mini.map { Int(($0.alphaValue * 100).rounded()) } ?? -1
        let level = Int(panel.level.rawValue)
        let side = i(PEQPanelMetrics.measuredSideHeight)
        let mid = i(PEQPanelMetrics.layout(
            bandCount: AppModel.shared.peqBands.count,
            screenMaxH: PEQPanelMetrics.activeScreenMaxH
        ).middleHeight)
        let cap = i(PEQPanelMetrics.activeScreenMaxH)
        return "stamp=\(Self.buildStamp) frame=\(i(panel.frame.height)) content=\(i(cv)) locked=\(i(lockedContentHeight)) side=\(side) mid=\(mid) cap=\(cap) level=\(level) closeOrigin=\(closeOrigin) miniAlpha=\(miniAlpha) zoomNil=\(zoom == nil)"
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
        // Fresh measure each open — stale measuredSideHeight from a prior layout can
        // disagree with the current side stack (profile/tone chrome changes).
        PEQPanelMetrics.measuredSideHeight = 0
        // Seed screen cap before first SwiftUI layout (mouse screen → laptop vs external).
        let mouse = NSEvent.mouseLocation
        let seedScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        PEQPanelMetrics.activeScreenMaxH = PEQPanelMetrics.usableHeight(on: seedScreen)

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

        // Always recreate — a reused window kept titlebar chrome that let the
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
        // Activate + key so opening from the menu extra brings EQ front once;
        // level stays `.normal` so other apps cover it afterward.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        configureChrome(on: panel)
        // One deferred settle after first layout — not a multi-pass hammer (that fought hosting).
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
        // Two quiet settles after hosting's first layout. More passes + setFrame fighting
        // previously burned a core while looking "frozen".
        let delays: [TimeInterval] = [0.05, 0.25]
        var last: DispatchWorkItem?
        for delay in delays {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.applySizing(reposition: false)
                if let panel = self.panel { self.configureChrome(on: panel) }
            }
            last = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        // Prefer the screen under the cursor (laptop vs external), then the panel's screen.
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? panel.screen
            ?? NSScreen.main
        let screenMaxH = PEQPanelMetrics.usableHeight(on: targetScreen)
        PEQPanelMetrics.activeScreenMaxH = screenMaxH
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
            if let screen = targetScreen {
                let visible = screen.visibleFrame
                origin.x = visible.midX - width / 2
                origin.y = visible.maxY - targetH - 8
            }
        } else if let screen = panel.screen ?? targetScreen {
            let visible = screen.visibleFrame
            if origin.y + targetH > visible.maxY {
                origin.y = visible.maxY - targetH - 8
            }
            if origin.y < visible.minY {
                origin.y = visible.minY + 8
            }
        }

        let locked = NSSize(width: width, height: targetH)
        // Lock BEFORE setFrame so any nested AppKit/hosting setFrame is clamped / dropped.
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
            // Only set the window frame — do NOT also setFrameSize on content/hosting
            // (that re-entered layout and fought ExactHeightEQPanel).
            panel.setFrame(targetFrame, display: true)
        }

        peqPanelLog.debug(
            "EQ size bands=\(bandCount) H=\(targetH, format: .fixed(precision: 0)) frame=\(panel.frame.height, format: .fixed(precision: 0)) stamp=\(Self.buildStamp)"
        )
    }

    private func configureChrome(on panel: ExactHeightEQPanel) {
        panel.animationBehavior = .none
        panel.level = .normal
        // Mini stays in the style mask so AppKit uses the standard first-slot close
        // position; alpha-hide mini/zoom. Never create/close a probe NSWindow here.
        panel.alignTrafficLights()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
    }

    private func makePanel() -> ExactHeightEQPanel {
        let width = Self.contentWidth
        let minH = PEQPanelMetrics.contentHeight(bandCount: PEQPanelMetrics.minBandCountFloor)
        // Include `.miniaturizable` so close uses the first standard traffic-light slot
        // (closable-only chrome packs close into the corner). No `.resizable` / zoom.
        let panel = ExactHeightEQPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: minH),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone]
        panel.isReleasedWhenClosed = false
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
        // ExactHeightEQPanel drops hostile resizes without calling super — no snap loop.
        // Do not re-enter applySizing from here (that was a CPU spin vector).
        _ = notification
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
