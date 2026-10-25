import SwiftUI

struct PEQView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false
    @State private var selectedBandID: UUID?
    @State private var scrollToBandID: UUID?
    @State private var showSaveProfile = false
    @State private var saveProfileName = ""
    @State private var pendingOverwriteName = ""
    @State private var showOverwriteConfirm = false
    @State private var confirmDeleteProfileID: UUID?

    private var controlsEnabled: Bool { model.isBridgeRunning }

    /// Minimum list height (auto-grow for 1–3; peek for 4+). Extra window height expands the list.
    private static let bandRowPitch: CGFloat = 36
    private static let bandPeekRows: CGFloat = 3.28

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

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

            globalsRow

            EQResponseGraph(
                bands: model.peqBands,
                sampleRate: graphSampleRate,
                selectedBandID: $selectedBandID,
                needleHz: model.peqSweepNeedleHz,
                sweepPlaying: model.peqSweepPlaying,
                enabled: controlsEnabled,
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
            .frame(height: 220)
            .layoutPriority(0)

            bandList
                .frame(minHeight: minBandListHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .layoutPriority(1)

            bottomBar
        }
        .padding(14)
        .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Reset EQ?", isPresented: $confirmReset, titleVisibility: .visible) {
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
        .confirmationDialog(
            "Already exists. Overwrite?",
            isPresented: $showOverwriteConfirm,
            titleVisibility: .visible
        ) {
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
        .confirmationDialog("Delete profile?", isPresented: Binding(
            get: { confirmDeleteProfileID != nil },
            set: { if !$0 { confirmDeleteProfileID = nil } }
        ), titleVisibility: .visible) {
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

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("EQ")
                .font(.headline)
            Spacer()
            Text(model.peqProfileDisplayName)
                .font(.subheadline)
                .foregroundStyle(model.peqProfileDirty ? Color.primary : Color.secondary)
                .lineLimit(1)
            profilesMenu
        }
    }

    private var profilesMenu: some View {
        Menu("Profiles") {
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
        }
        .controlSize(.small)
    }

    private var globalsRow: some View {
        HStack(alignment: .top, spacing: 14) {
            HStack(spacing: 8) {
                Text("Output Gain:")
                    .foregroundStyle(.secondary)
                EditableNumberField(
                    value: model.peqOutputGainDB,
                    format: "%+.1f",
                    suffix: " dB",
                    width: 72,
                    disabled: !controlsEnabled || model.peqAutoOutputGain
                ) { model.setPEQOutputGainDB($0) }
                Toggle("Auto", isOn: Binding(
                    get: { model.peqAutoOutputGain },
                    set: { model.setPEQAutoOutputGain($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!controlsEnabled)
                Button("Set To Safe") {
                    model.setPEQOutputGainToSafe()
                }
                .disabled(!controlsEnabled)
            }

            Divider().frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Bypass", isOn: Binding(
                    get: { model.peqBypass },
                    set: { model.setPEQBypass($0) }
                ))
                .toggleStyle(.button)
                .disabled(!controlsEnabled)
                Toggle("Gain Match", isOn: Binding(
                    get: { model.peqBypassGainMatch },
                    set: { model.setPEQBypassGainMatch($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!controlsEnabled)
            }

            Divider().frame(height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Tone Gain:")
                        .foregroundStyle(.secondary)
                    EditableNumberField(
                        value: model.peqToneLevelDB,
                        format: "%+.0f",
                        suffix: " dB",
                        width: 56,
                        disabled: !controlsEnabled
                    ) { model.setPEQToneLevelDB($0) }
                }
                HStack(spacing: 6) {
                    Button("Peak") {
                        if let id = model.applySweepPeak() {
                            selectedBandID = id
                            scrollToBandID = id
                            DispatchQueue.main.async {
                                PEQPanelController.shared.resizeToFitContent()
                            }
                        }
                    }
                    .disabled(!controlsEnabled || model.peqSweepNeedleHz == nil || (model.peqBands.count >= EQBand.maxBandCount && !hasPeakingNearNeedle))
                    Button("Dip") {
                        if let id = model.applySweepDip() {
                            selectedBandID = id
                            scrollToBandID = id
                            DispatchQueue.main.async {
                                PEQPanelController.shared.resizeToFitContent()
                            }
                        }
                    }
                    .disabled(!controlsEnabled || model.peqSweepNeedleHz == nil || (model.peqBands.count >= EQBand.maxBandCount && !hasPeakingNearNeedle))
                }
            }

            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var hasPeakingNearNeedle: Bool {
        guard let hz = model.peqSweepNeedleHz else { return false }
        return model.peqBands.contains { band in
            band.filterType == .peaking && abs(log(max(band.frequencyHz, 1) / max(hz, 1))) <= log(1.04)
        }
    }

    /// Preferred minimum when the window is compact; grows with 1–3 bands, peeks at 4+.
    private var minBandListHeight: CGFloat {
        let count = model.peqBands.count
        if count == 0 { return 8 }
        if count <= 3 {
            return CGFloat(count) * Self.bandRowPitch
        }
        return Self.bandPeekRows * Self.bandRowPitch
    }

    private var bandList: some View {
        Group {
            if model.peqBands.isEmpty {
                Color.clear.frame(minHeight: 8, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.peqBands.enumerated()), id: \.element.id) { index, band in
                            bandRow(index: index, band: band)
                                .id(band.id)
                                .listRowInsets(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 2))
                                .listRowSeparator(.visible)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { source, destination in
                            model.movePEQBands(from: source, to: destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var bottomBar: some View {
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
                Label("Add band", systemImage: "plus")
            }
            .disabled(!controlsEnabled || model.peqBands.count >= EQBand.maxBandCount)

            Spacer()

            Button("Reset") {
                confirmReset = true
            }
            .disabled(!controlsEnabled)
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func bandRow(index: Int, band: EQBand) -> some View {
        let selected = selectedBandID == band.id
        HStack(spacing: 8) {
            // Large drag affordance (List onMove) + reliable ↑/↓.
            Image(systemName: "line.3.horizontal")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 28)
                .contentShape(Rectangle())
                .help("Drag to reorder")

            VStack(spacing: 0) {
                Button {
                    _ = model.movePEQBand(id: band.id, by: -1)
                    selectedBandID = band.id
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 14)
                }
                .buttonStyle(.borderless)
                .disabled(!controlsEnabled || index == 0)
                .help("Move up")

                Button {
                    _ = model.movePEQBand(id: band.id, by: 1)
                    selectedBandID = band.id
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 14)
                }
                .buttonStyle(.borderless)
                .disabled(!controlsEnabled || index >= model.peqBands.count - 1)
                .help("Move down")
            }

            Text("\(index + 1)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 16, alignment: .trailing)

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
            .frame(width: 64)
            .disabled(!controlsEnabled)

            EditableLabeledValue(
                label: "F",
                value: band.frequencyHz,
                display: EQFormat.frequency(band.frequencyHz),
                width: 84,
                disabled: !controlsEnabled
            ) { hz in
                model.updatePEQBand(id: band.id) { $0.frequencyHz = hz }
            }

            EditableLabeledValue(
                label: "G",
                value: band.gainDB,
                display: String(format: "%+.1f dB", band.gainDB),
                width: 68,
                disabled: !controlsEnabled
            ) { gain in
                model.updatePEQBand(id: band.id) { $0.gainDB = gain }
            }

            EditableLabeledValue(
                label: "Q",
                value: band.q,
                display: String(format: "%.1f", band.q),
                width: 44,
                disabled: !controlsEnabled
            ) { q in
                model.updatePEQBand(id: band.id) { $0.q = q }
            }

            Spacer(minLength: 0)

            Button {
                if selectedBandID == band.id { selectedBandID = nil }
                model.removePEQBand(id: band.id)
                DispatchQueue.main.async {
                    PEQPanelController.shared.resizeToFitContent()
                }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(!controlsEnabled)
            .help("Remove band")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedBandID = band.id }
        .disabled(!controlsEnabled)
    }
}

// MARK: - Response graph

private struct EQResponseGraph: View {
    let bands: [EQBand]
    let sampleRate: Double
    @Binding var selectedBandID: UUID?
    let needleHz: Double?
    let sweepPlaying: Bool
    let enabled: Bool
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
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
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
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
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
        return Text("\(index + 1)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 18, height: 18)
            .background(Circle().fill(selected ? Color.accentColor : Color.teal))
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
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
        let points = PEQHeadroom.responseCurveDB(bands: bands, sampleRate: sampleRate, sampleCount: 160)
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: CGPoint(
            x: xPosition(for: first.hz, width: size.width),
            y: yPosition(for: first.db, height: size.height)
        ))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(
                x: xPosition(for: point.hz, width: size.width),
                y: yPosition(for: point.db, height: size.height)
            ))
        }
        context.stroke(path, with: .color(.teal), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
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

private enum EQFormat {
    static func frequency(_ hz: Double) -> String {
        if hz >= 1_000 {
            let k = hz / 1_000
            if abs(k - k.rounded()) < 0.05 {
                return String(format: "%.0f kHz", k.rounded())
            }
            return String(format: "%.2f kHz", k)
        }
        if hz >= 100 {
            return String(format: "%.0f Hz", hz)
        }
        return String(format: "%.1f Hz", hz)
    }
}

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
            return String(format: "%+.1f", value).replacingOccurrences(of: "+", with: "")
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

private struct EditableNumberField: View {
    let value: Double
    let format: String
    var suffix: String = ""
    let width: CGFloat
    let disabled: Bool
    let onCommit: (Double) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing && !disabled {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .frame(width: width)
                    .onSubmit { commit() }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                Text(String(format: format, value) + suffix)
                    .monospacedDigit()
                    .frame(width: width, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        guard !disabled else { return }
                        draft = String(format: format, value)
                            .replacingOccurrences(of: "+", with: "")
                        editing = true
                        focused = true
                    }
            }
        }
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
        onCommit(parsed)
    }
}
