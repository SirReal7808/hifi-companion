import SwiftUI

struct PEQView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmReset = false
    @State private var selectedBandID: UUID?
    @State private var scrollToBandID: UUID?
    @State private var showSaveProfile = false
    @State private var saveProfileName = ""
    @State private var pendingOverwriteName = ""
    @State private var showOverwriteConfirm = false
    @State private var confirmDeleteProfileID: UUID?

    /// Keep controls live across brief PT rebuilds so the EQ panel does not flash a banner
    /// and reflow when Music stops / sample rate changes.
    private var controlsEnabled: Bool { model.eqControlsAvailable }

    /// Side column width floor; row pitch comes from `PEQPanelMetrics` (shared with window H(N)).
    private static let sideControlsMinWidth: CGFloat = 268

    var body: some View {
        // spacing 0 at the root so Add Band / Reset are not pushed by the 12pt
        // section rhythm — chip inset alone sets the air above/below the buttons.
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                toolbarRow

                // No in-flow status banners — transient rebuild / disabled copy used to insert a
                // caption row, grow the VStack past H(N), and shove Peak/Dip under the footer.
                // Steady “enable PT” lives in the menu; clipping is an overlay on the graph.

                EQResponseGraph(
                    bands: model.peqBands,
                    sampleRate: graphSampleRate,
                    selectedBandID: $selectedBandID,
                    needleHz: model.peqSweepNeedleHz,
                    sweepPlaying: model.peqSweepPlaying,
                    enabled: controlsEnabled,
                    globallyBypassed: model.peqBypass,
                    onTuneDrag: { id, frequencyHz, gainDB in
                        model.previewPEQBandDrag(id: id, frequencyHz: frequencyHz, gainDB: gainDB)
                    },
                    onTuneDragEnded: {
                        model.commitPEQBandDrag()
                    },
                    onSweepChanged: { hz in
                        if model.peqSweepPlaying {
                            model.updatePEQSweep(atHz: hz)
                        } else {
                            model.beginPEQSweep(atHz: hz)
                        }
                    },
                    onSweepEnded: {
                        model.endPEQSweep()
                    }
                )
                .frame(height: panelLayout.graphHeight)
                .layoutPriority(0)
                // Bypass A/B must not animate Canvas / materials (jank + WindowServer load).
                .transaction { $0.animation = nil }
                .overlay(alignment: .topLeading) {
                    if model.peqClippingWarning {
                        Text("Output + peak boost exceeds 0 dB (clipping risk).")
                            .foregroundStyle(.red)
                            .font(.system(.caption))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .padding(8)
                            .allowsHitTesting(false)
                    }
                }

                // Intrinsic HStack (no height-scoped shell) so the side glass shadow and
                // bottom corners paint into the chip inset — fixed-height containers /
                // `.clipped()` / `.compositingGroup()` on this middle cut the glass
                // (compact-footer invariant: keep corners + shadow fully visible).
                HStack(alignment: .top, spacing: 12) {
                    bandList
                        .frame(
                            width: max(0, PEQPanelController.contentWidth - 28 - sideColumnWidth - 12),
                            height: panelLayout.middleHeight,
                            alignment: .top
                        )
                        .clipped()

                    sideControls
                        .frame(width: sideColumnWidth, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .onPreferenceChange(SideControlsHeightKey.self) { height in
                    applyMeasuredSideHeight(height)
                }
                .contentShape(Rectangle())
                .allowsHitTesting(!confirmReset && !showOverwriteConfirm && confirmDeleteProfileID == nil)
                // No layoutPriority here — a high priority let the middle eat leftover
                // height and opened a void above Add Band / Reset.
            }

            // COMPACT FOOTER INVARIANT (eq-footer-compact-v4): chips on the window
            // background — equal inset above/below, no strip. Do not wrap in a
            // fixed-height bar or place a layer that clips the side glass above.
            footerBar
                .padding(.top, PEQPanelMetrics.footerChipInset)
                .zIndex(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, PEQPanelMetrics.footerChipInset)
        .padding(.top, 2)
        .background(EQChrome.windowBackground)
        // Draw under the transparent titlebar (Music-style); leading inset clears traffic lights.
        // Ignore all safe areas — residual titlebar insets previously grew the NSPanel by ~32pt.
        .ignoresSafeArea()
        // Exact H(N)×W — never `maxHeight: .infinity`.
        .frame(
            width: PEQPanelController.contentWidth,
            height: panelLayout.contentHeight,
            alignment: .topLeading
        )
        // Use `.alert` (not confirmationDialog): in this floating NSPanel the dialog
        // overlay’s Cancel/Reset buttons were not receiving clicks (hit-testing).
        .alert("Reset EQ?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                selectedBandID = nil
                model.resetPEQFlat()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all bands and restore Output Gain to 0 dB.")
        }
        .alert("Save Profile", isPresented: $showSaveProfile) {
            TextField("Name", text: $saveProfileName)
            Button("Save") {
                attemptSaveProfile()
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: showSaveProfile) { _, isOpen in
            // Re-apply on present — setting the field in the same turn as `isPresented`
            // often leaves the TextField empty on macOS alerts.
            guard isOpen else { return }
            if let name = model.peqActiveProfileName, !name.isEmpty {
                saveProfileName = name
            }
        }
        .alert("Already exists. Overwrite?", isPresented: $showOverwriteConfirm) {
            Button("Overwrite", role: .destructive) {
                if model.savePEQProfile(named: pendingOverwriteName, overwrite: true) {
                    saveProfileName = ""
                    pendingOverwriteName = ""
                }
            }
            Button("Cancel", role: .cancel) {
                pendingOverwriteName = ""
            }
        }
        .alert("Delete profile?", isPresented: Binding(
            get: { confirmDeleteProfileID != nil },
            set: { if !$0 { confirmDeleteProfileID = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = confirmDeleteProfileID {
                    model.deletePEQProfile(id: id)
                }
                confirmDeleteProfileID = nil
            }
            Button("Cancel", role: .cancel) {
                confirmDeleteProfileID = nil
            }
        }
        .onChange(of: model.peqBands.map(\.id)) { _, ids in
            if let selected = selectedBandID, !ids.contains(selected) {
                selectedBandID = nil
            }
            // Defer past the current layout/display cycle — sync resize during
            // SwiftUI invalidation trips AppKit constraint crashes on add/delete.
            DispatchQueue.main.async {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    PEQPanelController.shared.resizeToFitContent()
                }
            }
        }
        .onAppear {
            model.refreshPEQProfileList()
            DispatchQueue.main.async {
                PEQPanelController.shared.resizeToFitContent()
            }
        }
        .onDisappear {
            model.mutePEQSweep()
        }
    }

    private func attemptSaveProfile() {
        let name = saveProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if model.peqProfileExists(named: name) {
            pendingOverwriteName = name
            showOverwriteConfirm = true
            return
        }
        if model.savePEQProfile(named: name, overwrite: false) {
            saveProfileName = ""
        }
    }

    private var graphSampleRate: Double {
        let live = model.graphSampleRateForAutomation()
        if live > 0 { return live }
        return model.deviceFormat?.sampleRate ?? 48_000
    }

    /// Screen-aware layout (graph / middle / H(N)) shared with `PEQPanelController`.
    private var panelLayout: PEQPanelMetrics.Layout {
        PEQPanelMetrics.layout(
            bandCount: model.peqBands.count,
            screenMaxH: PEQPanelMetrics.activeScreenMaxH
        )
    }

    /// Side column ≤36% of the inner content width (matches prior GeometryReader math).
    private var sideColumnWidth: CGFloat {
        let inner = PEQPanelController.contentWidth - 28 // horizontal padding 14×2
        return max(Self.sideControlsMinWidth, inner * 0.36)
    }

    // MARK: - Toolbar

    private var toolbarRow: some View {
        // Leading inset clears standard traffic lights under fullSizeContentView (Music-like).
        HStack(spacing: 8) {
            Color.clear.frame(width: 68, height: 1)

            circularChromeButton(
                systemName: "arrow.uturn.backward",
                help: "Undo (⌘Z)",
                disabled: !model.canUndoPEQ || !controlsEnabled
            ) {
                model.undoPEQ()
            }
            .keyboardShortcut("z", modifiers: .command)

            circularChromeButton(
                systemName: "arrow.uturn.forward",
                help: "Redo (⇧⌘Z)",
                disabled: !model.canRedoPEQ || !controlsEnabled
            ) {
                model.redoPEQ()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])

            // Alternate redo chord.
            Button {
                model.redoPEQ()
            } label: {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .keyboardShortcut("y", modifiers: .command)
            .disabled(!model.canRedoPEQ || !controlsEnabled)
            .accessibilityHidden(true)

            Spacer(minLength: 0)

            profilesMenu
        }
        .overlay {
            Text("HiFi Companion")
                .font(.system(.headline, weight: .semibold))
                .allowsHitTesting(false)
        }
        // Match traffic-light vertical band under fullSizeContentView.
        .frame(minHeight: 52)
        .padding(.top, 6)
    }

    private func circularChromeButton(
        systemName: String,
        help: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background {
            Circle()
                .fill(.regularMaterial)
                .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 4, y: 1.5)
                .overlay {
                    Circle()
                        .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.8)
                }
        }
        .help(help)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var profilesMenu: some View {
        Menu {
            Button("Save…") {
                // Prefill active profile (esp. when dirty `*`) so overwrite is one click.
                saveProfileName = model.peqActiveProfileName ?? ""
                // Defer present so the TextField picks up `saveProfileName` on macOS.
                DispatchQueue.main.async {
                    showSaveProfile = true
                }
            }
            .disabled(!controlsEnabled)

            if !model.peqProfileNames.isEmpty {
                Divider()
                ForEach(model.peqProfileNames, id: \.id) { item in
                    Button(item.name) {
                        if model.loadPEQProfile(id: item.id) {
                            selectedBandID = model.peqBands.first?.id
                            DispatchQueue.main.async {
                                PEQPanelController.shared.resizeToFitContent()
                            }
                        }
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(model.peqProfileNames, id: \.id) { item in
                        Button(item.name, role: .destructive) {
                            confirmDeleteProfileID = item.id
                        }
                    }
                }
            }
        } label: {
            Text(model.peqProfileDisplayName)
                .font(.system(.subheadline, weight: .medium))
                .lineLimit(1)
                .padding(.leading, 11)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background {
                    Capsule(style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 4, y: 1.5)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.8)
                        }
                }
        }
        .menuStyle(.borderlessButton)
        // Single trailing disclosure — do not add a custom chevron (would double).
        .menuIndicator(.visible)
        .disabled(!controlsEnabled && model.peqProfileNames.isEmpty)
    }

    // MARK: - Side controls (Output / Bypass / Tone)

    private var sideControls: some View {
        VStack(spacing: 0) {
            outputGainSection
            EQChrome.hairline
            bypassSection
            // Tone hairline lives at the top of `toneGainSection` so it stays
            // visibly paired with TONE GENERATOR (same style as Output|Bypass).
            toneGainSection
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.9)
                }
        }
        // Outside the material so corners stay visible; keep bloom inside chip inset.
        .shadow(color: EQChrome.footerSafeShadow(for: colorScheme), radius: 6, y: 2)
        // Report intrinsic height from the fixedSize glass — never from a tall proposal.
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: SideControlsHeightKey.self, value: geo.size.height)
            }
        }
        .opacity(controlsEnabled ? 1 : 0.55)
        .allowsHitTesting(controlsEnabled)
    }

    /// Accept a live side-glass height and snap ExactHeight to the new H(N).
    private func applyMeasuredSideHeight(_ height: CGFloat) {
        guard height.isFinite, height > 40 else { return }
        let listFloor = max(
            PEQPanelMetrics.listHeight(bandCount: model.peqBands.count),
            PEQPanelMetrics.listHeight(bandCount: PEQPanelMetrics.minBandCountFloor)
        )
        let middle = PEQPanelMetrics.layout(
            bandCount: model.peqBands.count,
            screenMaxH: PEQPanelMetrics.activeScreenMaxH
        ).middleHeight
        // Stretch echo: reported height == middle while list is shorter → ignore.
        if abs(height - middle) < 2, middle > listFloor + 2 {
            return
        }
        let prev = PEQPanelMetrics.measuredSideHeight
        guard abs(prev - height) > 1 else { return }
        PEQPanelMetrics.measuredSideHeight = height
        DispatchQueue.main.async {
            PEQPanelController.shared.resizeToFitContent(reposition: false)
        }
    }

    private var outputGainSection: some View {
        // Framed knob+dB (same chrome as GAIN LEVEL) and AUTO share the row equally.
        HStack(alignment: .center, spacing: 12) {
            framedGainStack(
                title: "OUTPUT GAIN",
                value: model.peqOutputGainDB,
                fractionDigits: 1,
                range: PEQHeadroom.minOutputGainDB...PEQHeadroom.maxOutputGainDB,
                step: 0.1,
                // The 60 dB range over one knob diameter was ~1.4 dB per point.
                dragDBPerPoint: 0.1,
                disabled: !controlsEnabled || model.peqAutoOutputGain,
                onKnobChange: { model.setPEQOutputGainDB($0, continuous: true) },
                onCommit: { model.setPEQOutputGainDB($0) }
            )
            .frame(maxWidth: .infinity)

            GlassToggleButton(
                title: "AUTO",
                isOn: Binding(
                    get: { model.peqAutoOutputGain },
                    set: { model.setPEQAutoOutputGain($0) }
                ),
                disabled: !controlsEnabled,
                fillsWidth: true
            )
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.bottom, 14)
    }

    /// Bordered label · knob · dB stack (OUTPUT GAIN / GAIN LEVEL).
    private func framedGainStack(
        title: String,
        value: Double,
        fractionDigits: Int,
        range: ClosedRange<Double>,
        step: Double,
        dragDBPerPoint: Double? = nil,
        disabled: Bool,
        onKnobChange: @escaping (Double) -> Void,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(.caption2, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GlassKnob(
                title: title,
                value: value,
                range: range,
                step: step,
                diameter: 44,
                dragUnitsPerPoint: dragDBPerPoint,
                disabled: disabled,
                onChange: onKnobChange
            )
            GlassGainField(
                value: value,
                fractionDigits: fractionDigits,
                range: range,
                disabled: disabled,
                prominence: .tone,
                onCommit: onCommit
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
        }
    }

    private var bypassSection: some View {
        // Middle peer section — hairlines above/below from `sideControls`.
        HStack(alignment: .center, spacing: 12) {
            GlassToggleButton(
                title: "BYPASS EQ",
                isOn: Binding(
                    get: { model.peqBypass },
                    set: { newValue in
                        var t = Transaction()
                        t.animation = nil
                        withTransaction(t) {
                            model.setPEQBypass(newValue)
                        }
                    }
                ),
                disabled: !controlsEnabled,
                fillsWidth: true
            )
            GlassCheckbox(
                title: "GAIN MATCH",
                isOn: Binding(
                    get: { model.peqBypassGainMatch },
                    set: { model.setPEQBypassGainMatch($0) }
                ),
                disabled: !controlsEnabled
            )
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 14)
    }

    private var toneGainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            EQChrome.hairline
            HStack(alignment: .firstTextBaseline) {
                Text("TONE GENERATOR")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Peak: -3dB | Dip: +3dB")
                    .font(.system(.caption2))
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 10) {
                framedGainStack(
                    title: "GAIN LEVEL",
                    value: model.peqToneLevelDB,
                    fractionDigits: 0,
                    range: SweepOscillator.minLevelDB...SweepOscillator.maxLevelDB,
                    step: 1,
                    disabled: !controlsEnabled,
                    onKnobChange: { model.setPEQToneLevelDB($0, continuous: true) },
                    onCommit: { model.setPEQToneLevelDB($0) }
                )
                .frame(width: 92)

                HStack(spacing: 10) {
                    peakDipButton(
                        title: "FIX PEAK",
                        accent: Color(red: 0.35, green: 0.55, blue: 0.95),
                        isPeak: true
                    ) {
                        if let id = model.applySweepPeak() {
                            selectedBandID = id
                            scrollToBandID = id
                            DispatchQueue.main.async {
                                PEQPanelController.shared.resizeToFitContent()
                            }
                        }
                    }
                    peakDipButton(
                        title: "FIX DIP",
                        accent: Color(red: 0.95, green: 0.55, blue: 0.32),
                        isPeak: false
                    ) {
                        if let id = model.applySweepDip() {
                            selectedBandID = id
                            scrollToBandID = id
                            DispatchQueue.main.async {
                                PEQPanelController.shared.resizeToFitContent()
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }

            Text("Click & drag on graph to sweep")
                .font(.system(.caption2))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 2)
        .padding(.bottom, 0)
    }

    private func peakDipButton(
        title: String,
        accent: Color,
        isPeak: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let enabled = controlsEnabled
            && model.peqSweepNeedleHz != nil
            && (model.peqBands.count < EQBand.maxBandCount || hasPeakingNearNeedle)
        return Button(action: action) {
            VStack(spacing: 10) {
                PeakDipIcon(isPeak: isPeak)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 56, height: 30)
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        // Fixed height — `maxHeight: .infinity` used to expand the glass when the
        // middle slot was taller than the intrinsic side stack.
        .frame(height: 108)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 6, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    accent.opacity(colorScheme == .dark ? 0.55 : 0.42),
                                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.55)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.1
                        )
                }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    private var hasPeakingNearNeedle: Bool {
        guard let hz = model.peqSweepNeedleHz else { return false }
        return model.peqBands.contains { band in
            band.filterType == .peaking && abs(log(max(band.frequencyHz, 1) / max(hz, 1))) <= log(1.04)
        }
    }

    // MARK: - Band list

    private var bandList: some View {
        Group {
            if model.peqBands.isEmpty {
                Color.clear.frame(minHeight: 8, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // No layout animation on band insert/remove — animated height
                        // changes drive NSHostingView.updateAnimatedWindowSize and crash
                        // AppKit constraint updates on × delete / reopen.
                        LazyVStack(spacing: PEQPanelMetrics.rowSpacing) {
                            ForEach(Array(model.peqBands.enumerated()), id: \.element.id) { index, band in
                                bandRow(index: index, band: band)
                                    .id(band.id)
                            }
                        }
                        .padding(.vertical, PEQPanelMetrics.listVerticalPadding / 2)
                        .transaction { $0.animation = nil }
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onChange(of: scrollToBandID) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.async {
                            // No animation — animated scroll + window resize crashes AppKit.
                            var t = Transaction()
                            t.disablesAnimations = true
                            withTransaction(t) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                            scrollToBandID = nil
                        }
                    }
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            Button {
                // `onChange(of: peqBands)` owns resize — no second size pass here.
                // No animation: layout-size animation on add races AppKit constraints.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    if let id = model.addPEQBand() {
                        selectedBandID = id
                        scrollToBandID = id
                    }
                }
            } label: {
                Text("Add Band")
                    .font(.system(.subheadline, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background { cushionChipBackground }
            .disabled(!controlsEnabled || model.peqBands.count >= EQBand.maxBandCount)
            .opacity((!controlsEnabled || model.peqBands.count >= EQBand.maxBandCount) ? 0.45 : 1)

            Spacer(minLength: 8)

            Button {
                confirmReset = true
            } label: {
                Text("Reset")
                    .font(.system(.subheadline, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background { cushionChipBackground }
            .disabled(!controlsEnabled)
            .opacity(controlsEnabled ? 1 : 0.45)
        }
        // Intrinsic chip row — never `.frame(height: footer…)` (that recreated the strip).
        .fixedSize(horizontal: false, vertical: true)
        .allowsHitTesting(true)
    }

    private var cushionChipBackground: some View {
        Capsule(style: .continuous)
            .fill(.regularMaterial)
            .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 4, y: 1.5)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.8)
            }
    }

    @ViewBuilder
    private func bandRow(index: Int, band: EQBand) -> some View {
        let selected = selectedBandID == band.id
        let bypassed = !band.enabled
        let tint = bypassed ? Color.secondary : EQBandPalette.color(at: index)
        HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
                .shadow(color: tint.opacity(bypassed ? 0 : 0.45), radius: 2, y: 0.5)

            VStack(spacing: 0) {
                Button {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        _ = model.movePEQBand(id: band.id, by: -1)
                    }
                    selectedBandID = band.id
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.borderless)
                .disabled(!controlsEnabled || index == 0)
                .help("Move up")

                Button {
                    var t = Transaction()
                    t.disablesAnimations = true
                    withTransaction(t) {
                        _ = model.movePEQBand(id: band.id, by: 1)
                    }
                    selectedBandID = band.id
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 12)
                }
                .buttonStyle(.borderless)
                .disabled(!controlsEnabled || index >= model.peqBands.count - 1)
                .help("Move down")
            }

            Text("\(index + 1)")
                .font(.system(.caption, design: .default).monospacedDigit().weight(.semibold))
                .foregroundStyle(selected && !bypassed ? tint : Color.secondary)
                .frame(width: 14, alignment: .trailing)

            // Menu (not Picker) — macOS Picker ignores frame width and crushed "F:".
            Menu {
                ForEach(EQFilterType.allCases, id: \.self) { type in
                    Button(type.shortLabel) {
                        model.updatePEQBand(id: band.id) { band in
                            let fromPeak = band.filterType == .peaking
                            let toShelf = type == .lowShelf || type == .highShelf
                            band.filterType = type
                            if fromPeak && toShelf {
                                band.q = 0.7
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(band.filterType.shortLabel)
                        .font(.system(.caption, design: .default).monospacedDigit().weight(.semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(!controlsEnabled)

            EditableLabeledValue(
                label: "F",
                value: band.frequencyHz,
                display: EQFormat.frequency(band.frequencyHz),
                width: 78,
                disabled: !controlsEnabled
            ) { hz in
                model.updatePEQBand(id: band.id) { $0.frequencyHz = hz }
            }
            .layoutPriority(1)

            EditableLabeledValue(
                label: "G",
                value: band.gainDB,
                display: EQFormat.gainDB(band.gainDB, fractionDigits: 1),
                width: 64,
                disabled: !controlsEnabled
            ) { gain in
                model.updatePEQBand(id: band.id) { $0.gainDB = gain }
            }
            .layoutPriority(1)

            EditableLabeledValue(
                label: "Q",
                value: band.q,
                display: String(format: "%.1f", band.q),
                width: 40,
                disabled: !controlsEnabled
            ) { q in
                model.updatePEQBand(id: band.id) { $0.q = q }
            }
            .layoutPriority(1)

            Spacer(minLength: 4)

            Button {
                model.updatePEQBand(id: band.id) { $0.enabled.toggle() }
            } label: {
                Image(systemName: bypassed ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(bypassed ? Color.secondary : Color.primary.opacity(0.75))
                    .frame(width: 20, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!controlsEnabled)
            .help(bypassed ? "Enable band" : "Bypass band")

            Button {
                if selectedBandID == band.id { selectedBandID = nil }
                // Nil animation — layout-size animation on remove races AppKit constraints.
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    model.removePEQBand(id: band.id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!controlsEnabled)
            .help("Remove band")
            .opacity(selected ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Fixed pitch so window H(N) matches visible rows (no empty gap under footer at max).
        .frame(height: PEQPanelMetrics.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: selected ? 6 : 4, y: 1.5)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            selected && !bypassed
                                ? tint.opacity(colorScheme == .dark ? 0.55 : 0.4)
                                : Color.white.opacity(colorScheme == .dark ? 0.18 : 0.55),
                            lineWidth: selected ? 1.1 : 0.8
                        )
                }
        }
        .opacity(bypassed ? 0.55 : 1)
        .contentShape(Rectangle())
        .onTapGesture { selectedBandID = band.id }
        .disabled(!controlsEnabled)
    }
}

// MARK: - Chrome helpers

/// Pure-SwiftUI checkbox so the blue fill shares layout with the box (no AppKit focus-ring drift on resize).
private struct GlassCheckbox: View {
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(isOn ? Color.accentColor : Color(nsColor: .controlBackgroundColor).opacity(0.55))
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isOn ? 0.05 : 0.28), lineWidth: 0.8)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 14, height: 14)
                Text(title)
                    .font(.system(.caption, weight: .semibold))
                    .tracking(0.2)
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "checked" : "unchecked")
        .accessibilityAddTraits(.isButton)
    }
}

/// Quiet Liquid Glass rotary — vertical drag + scroll wheel; indicator sweeps −135°…+135°.
private struct GlassKnob: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Spoken by VoiceOver (e.g. "OUTPUT GAIN").
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var diameter: CGFloat = 52
    /// Vertical drag sensitivity. nil = one diameter of drag covers the full range.
    var dragUnitsPerPoint: Double?
    var disabled: Bool = false
    let onChange: (Double) -> Void

    @State private var dragOriginValue: Double?
    @StateObject private var scrollBridge = KnobScrollBridge()

    private var normalized: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-9 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    /// 0 → −135°, 1 → +135° (270° travel, gap at bottom).
    private var indicatorDegrees: Double { -135 + normalized * 270 }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: colorScheme == .dark
                            ? [Color.white.opacity(0.14), Color.black.opacity(0.35)]
                            : [Color.white.opacity(0.95), Color(nsColor: .controlBackgroundColor)],
                        center: .topLeading,
                        startRadius: 2,
                        endRadius: diameter * 0.75
                    )
                )
                .overlay {
                    Circle()
                        .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.9)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12), radius: 3, y: 1.5)

            // Quiet track arc
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(90))
                .padding(diameter * 0.12)

            Capsule()
                .fill(Color.primary.opacity(disabled ? 0.35 : 0.85))
                .frame(width: max(2, diameter * 0.045), height: diameter * 0.28)
                .offset(y: -diameter * 0.22)
                .rotationEffect(.degrees(indicatorDegrees))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .background {
            // Pass-through AppKit view: hover + scroll wheel nudges by `step` (same as drag).
            KnobScrollCatcher(bridge: scrollBridge)
                .frame(width: diameter, height: diameter)
                .allowsHitTesting(false)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    guard !disabled else { return }
                    if dragOriginValue == nil { dragOriginValue = value }
                    let origin = dragOriginValue ?? value
                    // Up increases.
                    let delta: Double
                    if let perPoint = dragUnitsPerPoint {
                        delta = -gesture.translation.height * perPoint
                    } else {
                        // ~1 diameter of drag ≈ full range.
                        let span = range.upperBound - range.lowerBound
                        delta = -gesture.translation.height / max(diameter, 1) * span
                    }
                    let raw = origin + delta
                    let stepped = (raw / step).rounded() * step
                    let clamped = min(range.upperBound, max(range.lowerBound, stepped))
                    if abs(clamped - value) >= step * 0.49 - 1e-12 {
                        onChange(clamped)
                    }
                }
                .onEnded { _ in
                    dragOriginValue = nil
                }
        )
        .onAppear { syncScrollBridge() }
        .onChange(of: value) { _, _ in syncScrollBridge() }
        .onChange(of: step) { _, _ in syncScrollBridge() }
        .onChange(of: disabled) { _, _ in syncScrollBridge() }
        .opacity(disabled ? 0.45 : 1)
        .allowsHitTesting(!disabled)
        .accessibilityLabel(title)
        .accessibilityValue(Text("\(value, specifier: "%g") dB"))
        .accessibilityAdjustableAction { direction in
            guard !disabled else { return }
            switch direction {
            case .increment: onChange(min(range.upperBound, value + step))
            case .decrement: onChange(max(range.lowerBound, value - step))
            @unknown default: break
            }
        }
    }

    private func syncScrollBridge() {
        scrollBridge.value = value
        scrollBridge.step = step
        scrollBridge.range = range
        scrollBridge.disabled = disabled
        scrollBridge.onChange = onChange
    }
}

/// Live values for the scroll-wheel catcher (avoids stale SwiftUI captures).
@MainActor
private final class KnobScrollBridge: ObservableObject {
    var value: Double = 0
    var step: Double = 0.1
    var range: ClosedRange<Double> = -1...1
    var disabled: Bool = false
    var onChange: ((Double) -> Void)?
}

/// Tracking-area + local scroll monitor; `hitTest` is nil so SwiftUI keeps drag.
private struct KnobScrollCatcher: NSViewRepresentable {
    let bridge: KnobScrollBridge

    func makeNSView(context: Context) -> KnobScrollNSView {
        let view = KnobScrollNSView()
        view.bridge = bridge
        return view
    }

    func updateNSView(_ nsView: KnobScrollNSView, context: Context) {
        nsView.bridge = bridge
    }

    final class KnobScrollNSView: NSView {
        /// Soft scroll quantum (dB) — independent of drag `step` (tone drag stays 1 dB).
        private static let scrollStepDB: Double = 0.1
        /// One trackpad burst cannot jump several dB.
        private static let maxDBPerEvent: Double = 0.25
        /// Precise `scrollingDeltaY` points ≈ one `scrollStepDB`.
        private static let pointsPerScrollStep: Double = 12

        var bridge: KnobScrollBridge?
        private var monitor: Any?
        private var hovering = false
        /// Fractional remainder toward the next 0.1 dB tick.
        private var residualDB: Double = 0

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: .zero,
                    options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
                    owner: self,
                    userInfo: nil
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            residualDB = 0
            installMonitor()
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            residualDB = 0
            removeMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                hovering = false
                residualDB = 0
                removeMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.hovering, let bridge = self.bridge, !bridge.disabled else {
                    return event
                }
                guard self.window != nil else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc) else { return event }
                let dy = Double(event.scrollingDeltaY)
                guard abs(dy) > 0.05 else { return event }

                // Mouse wheel: positive dy → +dB (kept).
                // Trackpad (precise): invert so two-finger drag down decreases dB.
                let signedDY = event.hasPreciseScrollingDeltas ? -dy : dy
                let proposedDB: Double
                if event.hasPreciseScrollingDeltas {
                    proposedDB = signedDY / Self.pointsPerScrollStep * Self.scrollStepDB
                } else {
                    proposedDB = (signedDY > 0 ? 1 : -1) * Self.scrollStepDB
                }
                let clampedEvent = min(Self.maxDBPerEvent, max(-Self.maxDBPerEvent, proposedDB))
                self.residualDB += clampedEvent

                let ticks = (self.residualDB / Self.scrollStepDB).rounded(.towardZero)
                guard abs(ticks) >= 1 else { return nil }
                let change = min(Self.maxDBPerEvent, max(-Self.maxDBPerEvent, ticks * Self.scrollStepDB))
                self.residualDB -= change
                let next = min(bridge.range.upperBound, max(bridge.range.lowerBound, bridge.value + change))
                if abs(next - bridge.value) > 1e-12 {
                    bridge.onChange?(next)
                }
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

/// Frosted toggle button (Auto / Bypass EQ) — pressed look when on, not a switch or checkbox.
private struct GlassToggleButton: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    var fillsWidth: Bool = false

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(title)
                .font(.system(.caption, weight: .semibold))
                .tracking(0.4)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .padding(.horizontal, fillsWidth ? 14 : 12)
                .padding(.vertical, 9)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn
                      ? Color.accentColor.opacity(colorScheme == .dark ? 0.42 : 0.28)
                      : Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isOn
                                ? Color.accentColor.opacity(0.65)
                                : Color.primary.opacity(0.12),
                            lineWidth: 0.9
                        )
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05), radius: 2, y: 1)
        }
        .foregroundStyle(isOn ? Color.primary : Color.primary.opacity(0.85))
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isButton)
    }
}

private enum EQChrome {
    static var windowBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.55)
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    /// Section divider (Output | Bypass | Tone) — 1pt so it stays visible on retina glass.
    static var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    static func shadowColor(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.45) : Color.black.opacity(0.12)
    }

    /// Lighter than `shadowColor` so the bloom under the side glass doesn’t read as a footer bar.
    static func footerSafeShadow(for scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.28) : Color.black.opacity(0.10)
    }

    static func rimGradient(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: scheme == .dark
                ? [Color.white.opacity(0.28), Color.white.opacity(0.05)]
                : [Color.white.opacity(0.85), Color.white.opacity(0.15)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

private enum EQBandPalette {
    /// Soft band hues matching the approved refs (blue → teal → green → yellow → orange → pink).
    static let colors: [Color] = [
        Color(red: 0.47, green: 0.635, blue: 0.973),
        Color(red: 0.435, green: 0.820, blue: 0.835),
        Color(red: 0.545, green: 0.871, blue: 0.486),
        Color(red: 0.961, green: 0.843, blue: 0.431),
        Color(red: 0.976, green: 0.678, blue: 0.459),
        Color(red: 0.933, green: 0.647, blue: 0.765)
    ]

    static func color(at index: Int) -> Color {
        colors[index % colors.count]
    }
}

private struct PeakDipIcon: Shape {
    var isPeak: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let yBase = isPeak ? rect.maxY - 2 : rect.minY + 2
        let yTip = isPeak ? rect.minY + 2 : rect.maxY - 2
        path.move(to: CGPoint(x: rect.minX, y: yBase))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: yBase),
            control: CGPoint(x: rect.midX, y: yTip)
        )
        return path
    }
}

private enum GlassGainProminence {
    /// Output Gain — sketch-sized readout (no stepper).
    case output
    /// Tone GAIN LEVEL — smaller readout under the knob.
    case tone
}

/// Editable dB readout (click to type). No stepper arrows — knobs adjust value.
private struct GlassGainField: View {
    @Environment(\.colorScheme) private var colorScheme
    let value: Double
    var fractionDigits: Int = 1
    let range: ClosedRange<Double>
    let disabled: Bool
    var prominence: GlassGainProminence = .output
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var numberFont: Font {
        switch prominence {
        case .output: return .system(.title3, design: .default).monospacedDigit().weight(.semibold)
        case .tone: return .system(.subheadline, design: .default).monospacedDigit().weight(.medium)
        }
    }

    private var unitFont: Font {
        switch prominence {
        case .output: return .system(.subheadline, weight: .medium)
        case .tone: return .system(.caption, weight: .medium)
        }
    }

    private var minFieldHeight: CGFloat {
        switch prominence {
        case .output: return 36
        case .tone: return 28
        }
    }

    private var numberText: String {
        EQFormat.gainDB(value, fractionDigits: fractionDigits, includeUnit: false)
    }

    var body: some View {
        Group {
            if editing && !disabled {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .multilineTextAlignment(.center)
                    .font(numberFont)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(numberText)
                        .font(numberFont)
                    Text("dB")
                        .font(unitFont)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !disabled else { return }
                    draft = numberText
                    editing = true
                    focused = true
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, prominence == .tone ? 4 : 6)
        .frame(minHeight: minFieldHeight)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.45 : 0.65))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                }
        }
        .opacity(disabled ? 0.55 : 1)
    }

    private func commit() {
        defer {
            editing = false
            focused = false
        }
        let cleaned = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(cleaned) else { return }
        onCommit(min(range.upperBound, max(range.lowerBound, parsed)))
    }
}

// MARK: - Response graph

private struct EQResponseGraph: View {
    @Environment(\.colorScheme) private var colorScheme
    let bands: [EQBand]
    let sampleRate: Double
    @Binding var selectedBandID: UUID?
    let needleHz: Double?
    let sweepPlaying: Bool
    let enabled: Bool
    /// Global Bypass EQ — curve draws flat; handles stay for editing.
    var globallyBypassed: Bool = false
    let onTuneDrag: (UUID, Double, Double) -> Void
    let onTuneDragEnded: () -> Void
    let onSweepChanged: (Double) -> Void
    let onSweepEnded: () -> Void

    @State private var dragBandID: UUID?
    /// Band F/G when the handle press began — drags move relative to this, so a click
    /// anywhere on the 18 pt handle selects without nudging the band.
    @State private var dragOrigin: (hz: Double, db: Double)?
    /// True once the press actually moved the handle (a plain click is not an edit).
    @State private var didTuneDrag = false
    @State private var sweepDragging = false

    private let minDB = EQBand.minGainDB
    private let maxDB = EQBand.maxGainDB
    private let freqTicks: [Double] = [20, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000]
    private let gainTicks: [Double] = [-12, -8, -4, 0, 4, 8, 12]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.72 : 0.88))
                    .contentShape(Rectangle())
                    .gesture(sweepGesture(size: size))

                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize)
                    drawCurve(context: context, size: canvasSize)
                    if let needleHz {
                        drawNeedle(context: context, size: canvasSize, hz: needleHz, active: sweepPlaying || sweepDragging)
                    }
                }
                .allowsHitTesting(false)

                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    handleView(index: index, band: band, size: size)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.9)
            }
            .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 8, y: 2)
            .opacity(enabled ? 1 : 0.55)
            .allowsHitTesting(enabled)
        }
    }

    private func sweepGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled, dragBandID == nil else { return }
                sweepDragging = true
                let hz = frequency(atX: value.location.x, width: size.width)
                onSweepChanged(hz)
            }
            .onEnded { _ in
                if sweepDragging {
                    onSweepEnded()
                }
                sweepDragging = false
            }
    }

    private func handleView(index: Int, band: EQBand, size: CGSize) -> some View {
        let point = CGPoint(
            x: xPosition(for: band.frequencyHz, width: size.width),
            y: yPosition(for: band.gainDB, height: size.height)
        )
        let selected = selectedBandID == band.id || dragBandID == band.id
        let bypassed = !band.enabled
        let tint = bypassed ? Color.secondary.opacity(0.85) : EQBandPalette.color(at: index)
        return Text("\(index + 1)")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(bypassed ? Color.secondary : Color.white)
            .frame(width: 18, height: 18)
            .background(
                Circle()
                    .fill(tint)
                    .shadow(color: tint.opacity(bypassed ? 0 : (selected ? 0.55 : 0.3)), radius: selected ? 4 : 2)
            )
            .overlay(Circle().stroke(Color.white.opacity(bypassed ? 0.35 : 0.9), lineWidth: selected ? 1.5 : 1))
            .opacity(bypassed ? 0.7 : 1)
            .position(point)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        if sweepDragging {
                            onSweepEnded()
                            sweepDragging = false
                        }
                        dragBandID = band.id
                        selectedBandID = band.id
                        if dragOrigin == nil {
                            dragOrigin = (band.frequencyHz, band.gainDB)
                        }
                        // Ignore sub-point jitter so a click is never an edit.
                        guard didTuneDrag
                            || abs(value.translation.width) >= 1
                            || abs(value.translation.height) >= 1
                        else { return }
                        guard let origin = dragOrigin else { return }
                        didTuneDrag = true
                        let hz = frequency(
                            atX: xPosition(for: origin.hz, width: size.width) + value.translation.width,
                            width: size.width
                        )
                        let gain = gainDB(
                            atY: yPosition(for: origin.db, height: size.height) + value.translation.height,
                            height: size.height
                        )
                        onTuneDrag(band.id, hz, gain)
                    }
                    .onEnded { _ in
                        if didTuneDrag {
                            onTuneDragEnded()
                        }
                        dragBandID = nil
                        dragOrigin = nil
                        didTuneDrag = false
                    }
            )
    }

    private func drawGrid(context: GraphicsContext, size: CGSize) {
        var grid = Path()
        for hz in freqTicks {
            let x = xPosition(for: hz, width: size.width)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for db in gainTicks {
            let y = yPosition(for: db, height: size.height)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 1)

        var zero = Path()
        let y0 = yPosition(for: 0, height: size.height)
        zero.move(to: CGPoint(x: 0, y: y0))
        zero.addLine(to: CGPoint(x: size.width, y: y0))
        context.stroke(zero, with: .color(.primary.opacity(0.22)), lineWidth: 1)
    }

    private func drawCurve(context: GraphicsContext, size: CGSize) {
        // Per-band `enabled` is honored inside responseCurveDB via isAudiblyFlat;
        // global bypass draws a flat line without skipping handle editing.
        let plotBands = globallyBypassed ? [] : bands
        let points = PEQHeadroom.responseCurveDB(bands: plotBands, sampleRate: sampleRate, sampleCount: 180)
        guard let first = points.first else { return }

        var curve = Path()
        let firstPt = CGPoint(
            x: xPosition(for: first.hz, width: size.width),
            y: yPosition(for: first.db, height: size.height)
        )
        curve.move(to: firstPt)
        for point in points.dropFirst() {
            curve.addLine(to: CGPoint(
                x: xPosition(for: point.hz, width: size.width),
                y: yPosition(for: point.db, height: size.height)
            ))
        }

        // Soft multi-color wash under the curve (visible but not neon).
        var wash = curve
        let yFloor = size.height
        if let last = points.last {
            wash.addLine(to: CGPoint(x: xPosition(for: last.hz, width: size.width), y: yFloor))
            wash.addLine(to: CGPoint(x: xPosition(for: first.hz, width: size.width), y: yFloor))
            wash.closeSubpath()
        }
        let washGradient = Gradient(stops: washStops())
        context.fill(
            wash,
            with: .linearGradient(
                washGradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: 0)
            )
        )

        // Thin continuous curve with gentle per-band tinting along frequency.
        context.stroke(
            curve,
            with: .linearGradient(
                Gradient(stops: strokeStops()),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: 0)
            ),
            style: StrokeStyle(lineWidth: 2, lineJoin: .round)
        )
    }

    private func washStops() -> [Gradient.Stop] {
        if bands.isEmpty {
            return [
                .init(color: EQBandPalette.colors[0].opacity(0.10), location: 0),
                .init(color: EQBandPalette.colors[2].opacity(0.08), location: 0.5),
                .init(color: EQBandPalette.colors[5].opacity(0.10), location: 1)
            ]
        }
        let sorted = bands.enumerated().sorted { $0.element.frequencyHz < $1.element.frequencyHz }
        guard let first = sorted.first, let last = sorted.last else {
            return [
                .init(color: EQBandPalette.colors[0].opacity(0.10), location: 0),
                .init(color: EQBandPalette.colors[5].opacity(0.10), location: 1)
            ]
        }
        var stops: [Gradient.Stop] = [
            .init(color: EQBandPalette.color(at: first.offset).opacity(0.06), location: 0)
        ]
        for (offset, band) in sorted {
            let t = frequencyNormalized(band.frequencyHz)
            let color = band.enabled
                ? EQBandPalette.color(at: offset).opacity(0.16)
                : Color.secondary.opacity(0.04)
            stops.append(.init(color: color, location: t))
        }
        stops.append(
            .init(color: EQBandPalette.color(at: last.offset).opacity(0.06), location: 1)
        )
        return stops.sorted { $0.location < $1.location }
    }

    private func strokeStops() -> [Gradient.Stop] {
        if bands.isEmpty {
            return [
                .init(color: EQBandPalette.colors[1], location: 0),
                .init(color: EQBandPalette.colors[3], location: 1)
            ]
        }
        let sorted = bands.enumerated().sorted { $0.element.frequencyHz < $1.element.frequencyHz }
        var stops: [Gradient.Stop] = []
        for (offset, band) in sorted {
            let color = band.enabled
                ? EQBandPalette.color(at: offset).opacity(0.95)
                : Color.secondary.opacity(0.35)
            stops.append(.init(color: color, location: frequencyNormalized(band.frequencyHz)))
        }
        if let first = stops.first, first.location > 0.02 {
            stops.insert(.init(color: first.color.opacity(0.7), location: 0), at: 0)
        }
        if let last = stops.last, last.location < 0.98 {
            stops.append(.init(color: last.color.opacity(0.7), location: 1))
        }
        return stops.sorted { $0.location < $1.location }
    }

    private func frequencyNormalized(_ hz: Double) -> CGFloat {
        let lo = log(EQBand.minFrequencyHz)
        let hi = log(EQBand.maxFrequencyHz)
        return CGFloat((log(max(hz, EQBand.minFrequencyHz)) - lo) / (hi - lo))
    }

    private func drawNeedle(context: GraphicsContext, size: CGSize, hz: Double, active: Bool) {
        let x = xPosition(for: hz, width: size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(
            line,
            with: .color(active ? Color.orange : Color.primary.opacity(0.45)),
            style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [4, 3])
        )
        let label = EQFormat.frequency(hz)
        let text = Text(label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(active ? Color.orange : Color.primary.opacity(0.7))
        context.draw(
            context.resolve(text),
            at: CGPoint(x: min(max(x, 28), size.width - 28), y: 12),
            anchor: .center
        )
    }

    private func xPosition(for hz: Double, width: CGFloat) -> CGFloat {
        let lo = log(EQBand.minFrequencyHz)
        let hi = log(EQBand.maxFrequencyHz)
        let t = (log(max(hz, EQBand.minFrequencyHz)) - lo) / (hi - lo)
        return CGFloat(t) * width
    }

    private func yPosition(for db: Double, height: CGFloat) -> CGFloat {
        let t = (db - maxDB) / (minDB - maxDB)
        return CGFloat(t) * height
    }

    private func frequency(atX x: CGFloat, width: CGFloat) -> Double {
        let t = Double(min(max(x / max(width, 1), 0), 1))
        let lo = log(EQBand.minFrequencyHz)
        let hi = log(EQBand.maxFrequencyHz)
        return exp(lo + t * (hi - lo))
    }

    private func gainDB(atY y: CGFloat, height: CGFloat) -> Double {
        let t = Double(min(max(y / max(height, 1), 0), 1))
        return maxDB + t * (minDB - maxDB)
    }
}

// MARK: - Text editors

private struct EditableLabeledValue: View {
    let label: String
    let value: Double
    let display: String
    let width: CGFloat
    let disabled: Bool
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            // fixedSize — at the locked panel width a hungry Picker used to
            // compress "F:" into a clipped/garbled glyph.
            Text("\(label):")
                .foregroundStyle(.secondary)
                .font(.system(.caption, weight: .medium))
                .fixedSize()
                // Keep descenders (and the "F" glyph) inside the 40pt band row.
                .lineLimit(1)
            Group {
                if editing && !disabled {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .frame(width: width)
                        .font(.system(.caption, design: .default).monospacedDigit())
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                } else {
                    Text(display)
                        .font(.system(.caption, design: .default).monospacedDigit())
                        .frame(width: width, alignment: .leading)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard !disabled else { return }
                            draft = plainDraft(from: value)
                            editing = true
                            focused = true
                        }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    private func plainDraft(from value: Double) -> String {
        if label == "F" {
            if value >= 100 {
                return String(format: "%.0f", value)
            }
            return String(format: "%.1f", value)
        }
        if label == "G" {
            return EQFormat.gainDB(value, fractionDigits: 1, includeUnit: false)
        }
        return String(format: "%.1f", value)
    }

    private func commit() {
        defer {
            editing = false
            focused = false
        }
        var cleaned = draft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "dB", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        let lower = cleaned.lowercased()
        var scale = 1.0
        if lower.hasSuffix("khz") {
            cleaned = String(cleaned.dropLast(3)).trimmingCharacters(in: .whitespaces)
            scale = 1_000
        } else if lower.hasSuffix("hz") {
            cleaned = String(cleaned.dropLast(2)).trimmingCharacters(in: .whitespaces)
        } else if lower.hasSuffix("k") {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespaces)
            scale = 1_000
        }
        guard let parsed = Double(cleaned) else { return }
        onCommit(parsed * scale)
    }
}

/// Intrinsic side-glass height from `sideControls` (after `fixedSize`).
private struct SideControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}
