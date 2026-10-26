import AppKit
import SwiftUI
import os.log

private let peqPanelLog = Logger(subsystem: "HiFiCompanion", category: "PEQPanel")

/// Shared EQ panel vertical metrics — must stay in sync with `PEQView` chrome / band rows.
enum PEQPanelMetrics {
    static let contentWidth: CGFloat = 900
    /// Forced band-row height (matches `.frame(height:)` on each row).
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 8
    static let listVerticalPadding: CGFloat = 4
    /// Right-hand Output / Bypass / Tone column — intrinsic height of the glass stack
    /// (Output + Bypass + Tone + Peak/Dip), not a stretch target.
    static let sideControlsHeight: CGFloat = 372
    /// Absolute cap for measured side height (guards PreferenceKey / GeometryReader runaway).
    static let sideControlsHeightCap: CGFloat = 520
    /// Extra air between Peak/Dip and the footer so Reset never kisses Dip at min.
    static let footerClearance: CGFloat = 16
    /// Shortest allowed window matches the 4-band compact layout (+ clearance).
    static let minBandCountFloor = 4

    static func listHeight(bandCount: Int) -> CGFloat {
        if bandCount <= 0 { return 8 }
        let n = CGFloat(bandCount)
        return n * rowHeight + CGFloat(bandCount - 1) * rowSpacing + listVerticalPadding
    }

    /// Middle band/side region for a tight all-bands fit (no footer clearance void).
    static func middleHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        let side = clampedSideHeight(sideHeight)
        return max(listHeight(bandCount: bandCount), side)
    }

    /// Middle floor for the shortest window: side column + small gap above footer.
    static func minMiddleHeight(sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        clampedSideHeight(sideHeight) + footerClearance
    }

    /// Toolbar + graph + footer + paddings/gaps (banners omitted — rare while EQ is used).
    static var chromeHeight: CGFloat {
        let topPad: CGFloat = 2
        let bottomPad: CGFloat = 14
        let toolbar: CGFloat = 58
        let graph: CGFloat = 228
        let footer: CGFloat = 30
        let gaps: CGFloat = 36 // 3×12 between toolbar / graph / middle / footer
        return topPad + toolbar + graph + footer + bottomPad + gaps
    }

    /// Content height that exactly fits chrome + N band rows + footer (tight).
    static func contentHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        chromeHeight + middleHeight(bandCount: max(0, bandCount), sideHeight: sideHeight)
    }

    /// One notch taller than a pure H(4) list fit so Reset sits clearly below Dip.
    static func minContentHeight(sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        chromeHeight + max(
            listHeight(bandCount: minBandCountFloor),
            minMiddleHeight(sideHeight: sideHeight)
        )
    }

    /// Never below the min floor (N < 4 keeps empty space / unused slots).
    static func maxContentHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        max(contentHeight(bandCount: bandCount, sideHeight: sideHeight), minContentHeight(sideHeight: sideHeight))
    }

    /// Clamp PreferenceKey / GeometryReader side probes to a sane intrinsic range.
    static func clampedSideHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return sideControlsHeight }
        return min(max(height, sideControlsHeight), sideControlsHeightCap)
    }

    /// Fixed content height for a band count. Always `min == max >= 1`.
    ///
    /// Vertical drag is intentionally a no-op: the panel grows/shrinks only when
    /// bands are added or removed (and when the side column’s intrinsic height changes).
    /// A prior H(4)…H(N) resize range flickered as measurement / clamps raced, which
    /// also let the flexible middle region steal footer hits (Add Band / Reset).
    static func contentHeightLimits(
        bandCount: Int,
        sideHeight: CGFloat = sideControlsHeight,
        measuredTight: CGFloat? = nil,
        screenMaxH: CGFloat
    ) -> (min: CGFloat, max: CGFloat) {
        let sideFloor = clampedSideHeight(sideHeight)
        let floorMiddle = max(
            listHeight(bandCount: minBandCountFloor),
            sideFloor + footerClearance
        )
        let bandsMiddle = max(listHeight(bandCount: max(0, bandCount)), sideFloor)
        let formula = chromeHeight + max(bandsMiddle, floorMiddle)
        // Prefer a tight SwiftUI probe only when it agrees with the formula — never
        // open a min≠max range (that reintroduces intermittent bottom-edge resize).
        let ideal: CGFloat = {
            guard let measured = measuredTight, measured.isFinite, measured > 0 else {
                return formula
            }
            let usable = max(measured, chromeHeight + floorMiddle)
            if abs(usable - formula) <= 24 { return usable }
            return formula
        }()
        let screenCap = max(screenMaxH.isFinite ? screenMaxH : ideal, 1)
        let h = max(min(ideal, screenCap), 1)
        return (h, h)
    }

    /// Middle region height that matches `contentHeightLimits` (list / side / 4-band floor).
    static func middleRegionHeight(bandCount: Int, sideHeight: CGFloat = sideControlsHeight) -> CGFloat {
        let sideFloor = clampedSideHeight(sideHeight)
        let floorMiddle = max(
            listHeight(bandCount: minBandCountFloor),
            sideFloor + footerClearance
        )
        let bandsMiddle = max(listHeight(bandCount: max(0, bandCount)), sideFloor)
        return max(bandsMiddle, floorMiddle)
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
    /// SwiftUI-reported tight height (chrome + all rows, no void). Overrides formula when set.
    private var measuredTightContentHeight: CGFloat?
    /// Intrinsic side-column height from SwiftUI (Peak/Dip stack); raises the min floor when taller.
    private var measuredSideContentHeight: CGFloat = PEQPanelMetrics.sideControlsHeight
    /// Cached limits — AppKit can clear `maxSize` mid-resize on fullSizeContentView panels.
    private var lockedMinContentHeight: CGFloat = PEQPanelMetrics.minContentHeight()
    private var lockedMaxContentHeight: CGFloat = PEQPanelMetrics.minContentHeight()
    /// Prevents `windowDidResize` ↔ `applySizing` stack overflow / AppKit collapse.
    private var isApplyingSize = false
    private var pendingSizePass = false

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
        // Fixed H(N) content size — hosting fills the panel; no intrinsic auto-size fight.
        hosting.sizingOptions = []
        self.hosting = hosting

        // Recover if a prior bad size pass collapsed the panel frame (AppKit may hide it).
        if let existing = panel, existing.frame.width < 1 || existing.frame.height < 1 {
            peqPanelLog.error("EQ panel frame was degenerate (\(existing.frame.width)x\(existing.frame.height)); recreating")
            existing.orderOut(nil)
            existing.delegate = nil
            existing.contentViewController = nil
            panel = nil
            measuredTightContentHeight = nil
            measuredSideContentHeight = PEQPanelMetrics.sideControlsHeight
        }

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

    /// Called from SwiftUI when the tight “all bands visible” content height is measured.
    func updateMeasuredTightContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        // Ignore runaway probes (e.g. flexible maxHeight infinity layouts).
        let screenMaxH = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85
        let clamped = min(height, screenMaxH)
        if let previous = measuredTightContentHeight, abs(previous - clamped) < 1 {
            return
        }
        measuredTightContentHeight = clamped
        // Defer — PreferenceKey updates arrive during layout.
        DispatchQueue.main.async { [weak self] in
            self?.applySizing(reposition: false)
        }
    }

    /// Called from SwiftUI with the intrinsic side-column height (no stretch).
    func updateMeasuredSideContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 1 else { return }
        let capped = PEQPanelMetrics.clampedSideHeight(height)
        if abs(measuredSideContentHeight - capped) < 0.5 { return }
        if capped < height - 0.5 {
            peqPanelLog.debug("EQ side height capped \(height, format: .fixed(precision: 1)) → \(capped, format: .fixed(precision: 1))")
        }
        measuredSideContentHeight = capped
        DispatchQueue.main.async { [weak self] in
            self?.applySizing(reposition: false)
        }
    }

    /// Snap to fixed H(N) for the current band count; re-assert width lock.
    func resizeToFitContent(reposition: Bool = false) {
        // Band-count changes invalidate a prior measurement until SwiftUI reports again.
        measuredTightContentHeight = nil
        applySizing(reposition: reposition)
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
            sideHeight: measuredSideContentHeight,
            measuredTight: measuredTightContentHeight,
            screenMaxH: screenMaxH
        )
        // Fixed height: min == max. Soft clamp — never abort the app over sizing math.
        var contentMinH = max(limits.min, 1)
        var contentMaxH = max(limits.max, contentMinH)
        if abs(contentMaxH - contentMinH) > 0.5 {
            peqPanelLog.error("EQ limits not fixed min=\(contentMinH) max=\(contentMaxH); locking")
            contentMaxH = contentMinH
        }

        // Prefer contentView bounds (matches `setContentSize`) over contentLayoutRect,
        // which excludes the titlebar under fullSizeContentView and would look “short”.
        let rawCurrent = panel.contentView?.bounds.height ?? panel.contentLayoutRect.height
        let current = (rawCurrent.isFinite && rawCurrent > 0) ? rawCurrent : contentMinH
        let rawCurrentWidth = panel.contentView?.bounds.width ?? panel.contentLayoutRect.width
        let currentWidth = (rawCurrentWidth.isFinite && rawCurrentWidth > 0) ? rawCurrentWidth : width
        // Always snap to the fixed H(N) — no manual vertical lengthening.
        let safeHeight = max(contentMinH, 1)
        let safeWidth = max(width, 1)

        let oldFrame = panel.frame
        let topY = oldFrame.maxY
        let leftX = oldFrame.origin.x

        // When lowering max below the live frame, shrink content *before* applying the
        // final maxSize. Setting maxSize < current frame first can make AppKit collapse
        // / close floating panels (symptom: EQ vanishes on band delete).
        let shrinkingBelowCurrent = safeHeight < current - 1
        if shrinkingBelowCurrent {
            let interimMax = max(contentMaxH, current, contentMinH)
            applySizeLimits(on: panel, contentHeightMax: interimMax, contentHeightMin: contentMinH)
            panel.setContentSize(NSSize(width: safeWidth, height: safeHeight))
            applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
            peqPanelLog.debug("EQ shrink bands=\(bandCount) \(current, format: .fixed(precision: 1))→\(safeHeight, format: .fixed(precision: 1)) max=\(contentMaxH, format: .fixed(precision: 1))")
        } else {
            applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
            if abs(safeHeight - current) > 1 || abs(currentWidth - safeWidth) > 1 {
                panel.setContentSize(NSSize(width: safeWidth, height: safeHeight))
                // setContentSize can drift limits on some AppKit builds — re-assert.
                applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
            }
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
            frame.size.width = safeWidth
            if frame.size.height < 1 {
                frame.size.height = safeHeight
            }
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
            if frame.size.width >= 1, frame.size.height >= 1,
               frame.size.width.isFinite, frame.size.height.isFinite {
                panel.setFrame(frame, display: true)
            } else {
                peqPanelLog.error("EQ refused empty setFrame \(frame.size.width)x\(frame.size.height)")
            }
            applySizeLimits(on: panel, contentHeightMax: contentMaxH, contentHeightMin: contentMinH)
        }
    }

    private func applySizeLimits(on panel: NSPanel, contentHeightMax: CGFloat, contentHeightMin: CGFloat) {
        let width = Self.contentWidth
        // Never allow max < min — AppKit can collapse/close the window.
        let minH = max(contentHeightMin.isFinite ? contentHeightMin : 1, 1)
        let maxH = max(contentHeightMax.isFinite ? contentHeightMax : minH, minH)
        lockedMinContentHeight = minH
        lockedMaxContentHeight = maxH
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
        let minH = PEQPanelMetrics.minContentHeight()
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
        // Prefer locked limits — AppKit may clear panel.maxSize during live resize.
        // Height is fixed (min == max); bottom-edge drag must no-op consistently.
        let minW = Self.contentWidth
        let minH = lockedMinContentHeight > 1 ? lockedMinContentHeight : PEQPanelMetrics.minContentHeight()
        let maxH = max(lockedMaxContentHeight > 1 ? lockedMaxContentHeight : minH, minH)
        var size = frameSize
        size.width = minW
        size.height = min(max(size.height, minH), maxH)
        if !size.width.isFinite || size.width < 1 { size.width = Self.contentWidth }
        if !size.height.isFinite || size.height < 1 { size.height = minH }
        return size
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel, notification.object as? NSWindow === panel else { return }
        // Never call applySizing synchronously from didResize — setContentSize/setFrame
        // re-enter this delegate and can stack-overflow (hard quit on reopen).
        if isApplyingSize { return }
        applySizeLimits(
            on: panel,
            contentHeightMax: lockedMaxContentHeight,
            contentHeightMin: lockedMinContentHeight
        )
        let current = panel.contentView?.bounds.height ?? panel.frame.height
        guard current.isFinite else { return }
        if current > lockedMaxContentHeight + 1.5 || current < lockedMinContentHeight - 1.5 {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isApplyingSize else { return }
                self.applySizing(reposition: false)
            }
        }
    }

    private func positionNearMenuBar(_ panel: NSPanel) {
        let size = panel.frame.size
        guard size.width >= 1, size.height >= 1 else { return }
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
