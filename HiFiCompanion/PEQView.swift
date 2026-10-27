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
            .frame(height: 228)
            .layoutPriority(0)
            // Bypass A/B must not animate Canvas / materials (jank + WindowServer load).
            .transaction { $0.animation = nil }
            .overlay(alignment: .topLeading) {
                if model.peqClippingWarning {
                    Text("Output + peak boost exceeds 0 dB (clipping risk).")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }

            GeometryReader { geo in
                // Keep side ≤36% so F/G/Q labels keep a full-width slot in the band column.
                let sideW = max(Self.sideControlsMinWidth, geo.size.width * 0.36)
                HStack(alignment: .top, spacing: 12) {
                    bandList
                        .frame(width: max(0, geo.size.width - sideW - 12), height: geo.size.height, alignment: .top)

                    // Hug intrinsic height — do not stretch the glass into a void above the footer.
                    sideControls
                        .frame(width: sideW, alignment: .top)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                // Absorb leftover hits inside the middle slot so they never reach past the footer.
                // Disabled while a modal alert is up — otherwise the middle hit target can
                // steal Cancel/Reset clicks from the Reset EQ alert in this floating panel.
                .contentShape(Rectangle())
                .allowsHitTesting(!confirmReset && !showOverwriteConfirm && confirmDeleteProfileID == nil)
            }
            // Exact middle height matching fixed H(N).
            .frame(height: middleRegionHeight)
            .frame(maxWidth: .infinity)
            // compositingGroup so the side-card drop shadow is actually clipped (plain
            // `.clipped()` lets soft shadows paint over Add Band / Reset).
            .compositingGroup()
            .clipped()
            // Clearance below middle — not footer padding — keeps the footer strip tight.
            .padding(.bottom, PEQPanelMetrics.footerClearance)

            footerBar
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
            height: panelContentHeight,
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

    /// Matches `PEQPanelMetrics.middleRegionHeight` / fixed window H(N).
    private var middleRegionHeight: CGFloat {
        PEQPanelMetrics.middleRegionHeight(bandCount: model.peqBands.count)
    }

    /// Exact panel content height for the current band count (min == max).
    private var panelContentHeight: CGFloat {
        PEQPanelMetrics.contentHeight(bandCount: model.peqBands.count)
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
                .font(.system(.headline, design: .default).weight(.semibold))
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
                .font(.subheadline.weight(.medium))
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
                .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 10, y: 3)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(EQChrome.rimGradient(for: colorScheme), lineWidth: 0.9)
                }
        }
        // Side height is a compile-time constant in `PEQPanelMetrics` — live
        // GeometryReader probes read the proposed middle height and inflated H(N).
        .opacity(controlsEnabled ? 1 : 0.55)
        .allowsHitTesting(controlsEnabled)
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
                disabled: !controlsEnabled || model.peqAutoOutputGain
            ) { model.setPEQOutputGainDB($0) }
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
        disabled: Bool,
        onChange: @escaping (Double) -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            GlassKnob(
                value: value,
                range: range,
                step: step,
                diameter: 44,
                disabled: disabled,
                onChange: onChange
            )
            GlassGainField(
                value: value,
                fractionDigits: fractionDigits,
                range: range,
                disabled: disabled,
                prominence: .tone,
                onCommit: onChange
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Peak: -3dB | Dip: +3dB")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .top, spacing: 10) {
                framedGainStack(
                    title: "GAIN LEVEL",
                    value: model.peqToneLevelDB,
                    fractionDigits: 0,
                    range: SweepOscillator.minLevelDB...SweepOscillator.maxLevelDB,
                    step: 1,
                    disabled: !controlsEnabled
                ) { model.setPEQToneLevelDB($0) }
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
                .font(.caption2)
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
                    .font(.caption.weight(.semibold))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 108)
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
                    .font(.subheadline.weight(.medium))
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
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background { cushionChipBackground }
            .disabled(!controlsEnabled)
            .opacity(controlsEnabled ? 1 : 0.45)
        }
        // Fixed strip: chip (~31) + 2×footerChipInset — equal air above/below buttons.
        .frame(height: PEQPanelMetrics.footerHeight, alignment: .center)
        // Explicit hit target so a taller hosting view cannot leave the chips unclickable.
        .contentShape(Rectangle())
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
                .font(.caption.monospacedDigit().weight(.semibold))
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
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
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
                    .font(.caption.weight(.semibold))
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
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var diameter: CGFloat = 52
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
                    // Up increases; ~1 diameter of drag ≈ full range.
                    let span = range.upperBound - range.lowerBound
                    let delta = -gesture.translation.height / max(diameter, 1) * span
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
        .accessibilityLabel("Knob")
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
        var bridge: KnobScrollBridge?
        private var monitor: Any?
        private var hovering = false

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
            installMonitor()
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            removeMonitor()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                hovering = false
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
                guard let window = self.window else { return event }
                let loc = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(loc) else { return event }
                let dy = event.scrollingDeltaY
                guard abs(dy) > 0.1 else { return event }
                // Scroll up → increase (same direction as drag-up).
                let direction: Double = dy > 0 ? 1 : -1
                let next = min(bridge.range.upperBound, max(bridge.range.lowerBound, bridge.value + direction * bridge.step))
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
                .font(.caption.weight(.semibold))
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
        case .output: return .title3.monospacedDigit().weight(.semibold)
        case .tone: return .subheadline.monospacedDigit().weight(.medium)
        }
    }

    private var unitFont: Font {
        switch prominence {
        case .output: return .subheadline.weight(.medium)
        case .tone: return .caption.weight(.medium)
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
            .font(.system(size: 10, weight: .bold, design: .rounded))
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
                        let hz = frequency(atX: value.location.x, width: size.width)
                        let gain = gainDB(atY: value.location.y, height: size.height)
                        onTuneDrag(band.id, hz, gain)
                    }
                    .onEnded { _ in
                        if dragBandID != nil {
                            onTuneDragEnded()
                        }
                        dragBandID = nil
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
            .font(.system(size: 10, weight: .semibold, design: .rounded))
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
                .font(.caption.weight(.medium))
                .fixedSize()
                // Keep descenders (and the "F" glyph) inside the 40pt band row.
                .lineLimit(1)
            Group {
                if editing && !disabled {
                    TextField("", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .frame(width: width)
                        .font(.caption.monospacedDigit())
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                } else {
                    Text(display)
                        .font(.caption.monospacedDigit())
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
