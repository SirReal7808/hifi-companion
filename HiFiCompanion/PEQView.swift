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
    /// Intrinsic height of the side glass stack (Output / Bypass / Tone / Peak-Dip).
    @State private var measuredSideHeight: CGFloat = PEQPanelMetrics.sideControlsHeight

    private var controlsEnabled: Bool { model.isBridgeRunning }

    /// Side column width floor; row pitch comes from `PEQPanelMetrics` (shared with window H(N)).
    private static let sideControlsMinWidth: CGFloat = 268

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            toolbarRow

            if !controlsEnabled {
                Text(model.testEQDisabledReason.isEmpty ? "Enable Pass-through first" : model.testEQDisabledReason)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            if model.peqClippingWarning {
                Text("Output + peak boost exceeds 0 dB (clipping risk).")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

            GeometryReader { geo in
                let sideW = max(Self.sideControlsMinWidth, geo.size.width * 0.42)
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
            // Exact middle height matching fixed H(N) — no flexible maxHeight that can bleed hits.
            .frame(height: middleRegionHeight)
            .frame(maxWidth: .infinity)
            .clipped()

            footerBar
                // Keep Add Band / Reset above any middle-region hit bleed.
                .zIndex(1)
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
        .padding(.top, 2)
        // Panel height is fixed to H(N); top-align chrome so footer stays in the hit area.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(EQChrome.windowBackground)
        // Draw under the transparent titlebar (Music-style); leading inset clears traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        // Fixed width matches the panel lock — band F/G/Q must fit without stretching.
        .frame(
            minWidth: PEQPanelController.contentWidth,
            idealWidth: PEQPanelController.contentWidth,
            maxWidth: PEQPanelController.contentWidth,
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
            DispatchQueue.main.async {
                PEQPanelController.shared.resizeToFitContent()
                reportTightContentHeight()
            }
        }
        .onChange(of: measuredSideHeight) { _, _ in
            reportTightContentHeight()
        }
        .onAppear {
            model.refreshPEQProfileList()
            DispatchQueue.main.async {
                PEQPanelController.shared.resizeToFitContent()
                reportTightContentHeight()
            }
        }
        .onDisappear {
            model.mutePEQSweep()
        }
    }

    /// Tight window height = chrome + max(all band rows, measured side column).
    private func reportTightContentHeight() {
        let list = PEQPanelMetrics.listHeight(bandCount: model.peqBands.count)
        let side = PEQPanelMetrics.clampedSideHeight(measuredSideHeight)
        let middle = max(list, side)
        let tight = PEQPanelMetrics.chromeHeight + middle
        PEQPanelController.shared.updateMeasuredTightContentHeight(tight)
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
        PEQPanelMetrics.middleRegionHeight(
            bandCount: model.peqBands.count,
            sideHeight: measuredSideHeight
        )
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
                saveProfileName = model.peqActiveProfileName ?? ""
                showSaveProfile = true
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
            EQChrome.hairline
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
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SideControlsHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(SideControlsHeightKey.self) { height in
            guard height.isFinite, height > 1 else { return }
            // Quantize to whole points — sub-point GeometryReader chatter was
            // re-entering applySizing and keeping the EQ panel near 90% CPU idle.
            let capped = PEQPanelMetrics.clampedSideHeight(height).rounded()
            guard abs(capped - measuredSideHeight) > 1 else { return }
            measuredSideHeight = capped
            PEQPanelController.shared.updateMeasuredSideContentHeight(capped)
        }
        .opacity(controlsEnabled ? 1 : 0.55)
        .allowsHitTesting(controlsEnabled)
    }

    private var outputGainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Gain")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            GlassGainField(
                value: model.peqOutputGainDB,
                fractionDigits: 1,
                step: 0.1,
                range: PEQHeadroom.minOutputGainDB...PEQHeadroom.maxOutputGainDB,
                disabled: !controlsEnabled || model.peqAutoOutputGain
            ) { model.setPEQOutputGainDB($0) }
            // SwiftUI-drawn checkbox — AppKit `.checkbox` focus/fill chrome drifts during live resize.
            GlassCheckbox(
                title: "Auto",
                isOn: Binding(
                    get: { model.peqAutoOutputGain },
                    set: { model.setPEQAutoOutputGain($0) }
                ),
                disabled: !controlsEnabled
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 12)
    }

    private var bypassSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Bypass EQ", isOn: Binding(
                get: { model.peqBypass },
                set: { newValue in
                    // Avoid animating the whole frosted panel / graph on A/B — that felt
                    // low-FPS and contributed to WindowServer load.
                    var t = Transaction()
                    t.animation = nil
                    withTransaction(t) {
                        model.setPEQBypass(newValue)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.regular)
            .disabled(!controlsEnabled)
            GlassCheckbox(
                title: "Gain Match",
                isOn: Binding(
                    get: { model.peqBypassGainMatch },
                    set: { model.setPEQBypassGainMatch($0) }
                ),
                disabled: !controlsEnabled
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }

    private var toneGainSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tone Gain")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            GlassGainField(
                value: model.peqToneLevelDB,
                fractionDigits: 0,
                step: 1,
                range: SweepOscillator.minLevelDB...SweepOscillator.maxLevelDB,
                disabled: !controlsEnabled
            ) { model.setPEQToneLevelDB($0) }

            HStack(spacing: 8) {
                peakDipButton(
                    title: "Peak",
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
                    title: "Dip",
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
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
            VStack(spacing: 6) {
                PeakDipIcon(isPeak: isPeak)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 36, height: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: EQChrome.shadowColor(for: colorScheme), radius: 5, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    accent.opacity(colorScheme == .dark ? 0.45 : 0.35),
                                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.55)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.9
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
                        LazyVStack(spacing: PEQPanelMetrics.rowSpacing) {
                            ForEach(Array(model.peqBands.enumerated()), id: \.element.id) { index, band in
                                bandRow(index: index, band: band)
                                    .id(band.id)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.vertical, PEQPanelMetrics.listVerticalPadding / 2)
                        .animation(.easeInOut(duration: 0.22), value: model.peqBands.map(\.id))
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .onChange(of: scrollToBandID) { _, id in
                        guard let id else { return }
                        DispatchQueue.main.async {
                            withAnimation(.easeInOut(duration: 0.2)) {
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
                if let id = model.addPEQBand() {
                    selectedBandID = id
                    scrollToBandID = id
                    DispatchQueue.main.async {
                        PEQPanelController.shared.resizeToFitContent()
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
        .padding(.top, 2)
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
                    withAnimation(.easeInOut(duration: 0.22)) {
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
                    withAnimation(.easeInOut(duration: 0.22)) {
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

            Picker("Type", selection: Binding(
                get: { band.filterType },
                set: { type in
                    model.updatePEQBand(id: band.id) { band in
                        let fromPeak = band.filterType == .peaking
                        let toShelf = type == .lowShelf || type == .highShelf
                        band.filterType = type
                        if fromPeak && toShelf {
                            band.q = 0.7
                        }
                    }
                }
            )) {
                ForEach(EQFilterType.allCases, id: \.self) { type in
                    Text(type.shortLabel).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 58)
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

            EditableLabeledValue(
                label: "G",
                value: band.gainDB,
                display: EQFormat.gainDB(band.gainDB, fractionDigits: 1),
                width: 64,
                disabled: !controlsEnabled
            ) { gain in
                model.updatePEQBand(id: band.id) { $0.gainDB = gain }
            }

            EditableLabeledValue(
                label: "Q",
                value: band.q,
                display: String(format: "%.1f", band.q),
                width: 40,
                disabled: !controlsEnabled
            ) { q in
                model.updatePEQBand(id: band.id) { $0.q = q }
            }

            Spacer(minLength: 0)

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
                // `onChange(of: peqBands)` owns resize — avoid a second sync size pass here.
                model.removePEQBand(id: band.id)
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

private struct SideControlsHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
                    .font(.subheadline)
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

private enum EQChrome {
    static var windowBackground: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.55)
            Rectangle().fill(.ultraThinMaterial)
        }
    }

    static var hairline: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
            .padding(.vertical, 2)
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

private struct GlassGainField: View {
    @Environment(\.colorScheme) private var colorScheme
    let value: Double
    var fractionDigits: Int = 1
    let step: Double
    let range: ClosedRange<Double>
    let disabled: Bool
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var displayText: String {
        EQFormat.gainDB(value, fractionDigits: fractionDigits, includeUnit: true)
    }

    private var draftText: String {
        EQFormat.gainDB(value, fractionDigits: fractionDigits, includeUnit: false)
    }

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if editing && !disabled {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .multilineTextAlignment(.center)
                        .font(.title3.monospacedDigit().weight(.medium))
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                } else {
                    Text(displayText)
                        .font(.title3.monospacedDigit().weight(.medium))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard !disabled else { return }
                            draft = draftText
                            editing = true
                            focused = true
                        }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: 0) {
                Button {
                    onCommit(min(range.upperBound, value + step))
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 28, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(disabled || value >= range.upperBound - 1e-9)

                Button {
                    onCommit(max(range.lowerBound, value - step))
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 28, height: 18)
                }
                .buttonStyle(.borderless)
                .disabled(disabled || value <= range.lowerBound + 1e-9)
            }
            .padding(.trailing, 4)
        }
        .padding(.leading, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.55 : 0.72))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.8)
                }
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.06), radius: 2, y: 1)
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
        HStack(spacing: 2) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .font(.caption)
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
