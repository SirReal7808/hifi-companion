import SwiftUI

private enum EQPanelMode: String, CaseIterable, Identifiable {
    case tune
    case sweep

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tune: return "Tune"
        case .sweep: return "Sweep"
        }
    }
}

struct PEQView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false
    @State private var mode: EQPanelMode = .tune
    @State private var selectedBandID: UUID?

    private var controlsEnabled: Bool { model.isBridgeRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if !controlsEnabled {
                Text(model.testEQDisabledReason.isEmpty ? "Enable Pass-through first" : model.testEQDisabledReason)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                Text(model.eqStatusText)
                    .font(.caption)
                    .foregroundStyle(model.isEQActive ? Color.primary : Color.secondary)
            }

            if model.peqClippingWarning {
                Text("Output + peak boost exceeds 0 dB (clipping risk). Lower Output Gain or reduce boosts.")
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            globalsRow

            Text(String(format: "Peak boost ≈ +%.1f dB · safe out ≤ %+.1f dB", model.peqPeakBoostDB, model.peqSafeCeilingDB))
                .font(.caption2)
                .foregroundStyle(.secondary)

            EQResponseGraph(
                bands: model.peqBands,
                sampleRate: graphSampleRate,
                mode: mode,
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

            if mode == .sweep {
                Text(sweepHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            bandList

            bottomBar
        }
        .padding(14)
        .frame(minWidth: 560, idealWidth: 560)
        .confirmationDialog("Reset EQ?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                selectedBandID = nil
                model.resetPEQFlat()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Remove all bands and restore Output Gain to 0 dB.")
        }
        .onChange(of: model.peqBands.map(\.id)) { _, ids in
            if let selected = selectedBandID, !ids.contains(selected) {
                selectedBandID = nil
            }
        }
        .onChange(of: mode) { _, newMode in
            if newMode != .sweep {
                model.mutePEQSweep()
            }
        }
        .onDisappear {
            model.mutePEQSweep()
        }
    }

    private var sweepHint: String {
        if let hz = model.peqSweepNeedleHz {
            let parked = EQFormat.frequency(hz)
            if model.peqSweepPlaying {
                return "Sweeping \(parked) — release to mute and park the needle."
            }
            return "Needle parked at \(parked). Peak / Dip add a peaking band there."
        }
        return "Press-drag on the graph to play a tone; release mutes and parks the needle."
    }

    private var graphSampleRate: Double {
        let live = model.graphSampleRateForAutomation()
        if live > 0 { return live }
        return model.deviceFormat?.sampleRate ?? 48_000
    }

    private var headerRow: some View {
        HStack {
            Text("EQ")
                .font(.headline)
            Spacer()
            Picker("Mode", selection: $mode) {
                ForEach(EQPanelMode.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            .disabled(!controlsEnabled)
        }
    }

    private var globalsRow: some View {
        HStack(alignment: .top, spacing: 16) {
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
                Button("Set safe") {
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
                Toggle("Gain match", isOn: Binding(
                    get: { model.peqBypassGainMatch },
                    set: { model.setPEQBypassGainMatch($0) }
                ))
                .toggleStyle(.checkbox)
                .disabled(!controlsEnabled)
            }

            if mode == .sweep {
                Divider().frame(height: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Tone:")
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
                            }
                        }
                        .disabled(!controlsEnabled || model.peqSweepNeedleHz == nil || (model.peqBands.count >= EQBand.maxBandCount && !hasPeakingNearNeedle))
                        Button("Dip") {
                            if let id = model.applySweepDip() {
                                selectedBandID = id
                            }
                        }
                        .disabled(!controlsEnabled || model.peqSweepNeedleHz == nil || (model.peqBands.count >= EQBand.maxBandCount && !hasPeakingNearNeedle))
                    }
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

    private var bandList: some View {
        Group {
            if model.peqBands.isEmpty {
                Text("No bands — add one to shape the response.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.peqBands.enumerated()), id: \.element.id) { index, band in
                            bandRow(index: index, band: band)
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(minHeight: 36, idealHeight: bandListIdealHeight, maxHeight: 260)
                .clipped()
            }
        }
    }

    private var bandListIdealHeight: CGFloat {
        let row: CGFloat = 30
        let count = CGFloat(max(model.peqBands.count, 1))
        return min(260, max(36, count * row))
    }

    private var bottomBar: some View {
        HStack {
            Button {
                if let id = model.addPEQBand() {
                    selectedBandID = id
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
        HStack(spacing: 10) {
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
                width: 88,
                disabled: !controlsEnabled
            ) { hz in
                model.updatePEQBand(id: band.id) { $0.frequencyHz = hz }
            }

            EditableLabeledValue(
                label: "G",
                value: band.gainDB,
                display: String(format: "%+.1f dB", band.gainDB),
                width: 72,
                disabled: !controlsEnabled
            ) { gain in
                model.updatePEQBand(id: band.id) { $0.gainDB = gain }
            }

            EditableLabeledValue(
                label: "Q",
                value: band.q,
                display: String(format: "%.1f", band.q),
                width: 48,
                disabled: !controlsEnabled
            ) { q in
                model.updatePEQBand(id: band.id) { $0.q = q }
            }

            Spacer(minLength: 0)

            Button {
                if selectedBandID == band.id { selectedBandID = nil }
                model.removePEQBand(id: band.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .disabled(!controlsEnabled)
            .help("Remove band")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
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
    let mode: EQPanelMode
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

                Canvas { context, canvasSize in
                    drawGrid(context: context, size: canvasSize)
                    drawCurve(context: context, size: canvasSize)
                    if let needleHz {
                        drawNeedle(context: context, size: canvasSize, hz: needleHz, active: sweepPlaying || sweepDragging)
                    }
                }
                .allowsHitTesting(false)

                if mode == .tune {
                    ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                        handleView(index: index, band: band, size: size)
                    }
                } else {
                    // Band markers stay visible in Sweep but are not draggable.
                    ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                        markerView(index: index, band: band, size: size)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(mode == .sweep ? sweepGesture(size: size) : nil)
            .opacity(enabled ? 1 : 0.55)
            .allowsHitTesting(enabled)
        }
    }

    private func sweepGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard enabled else { return }
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
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

    private func markerView(index: Int, band: EQBand, size: CGSize) -> some View {
        let point = CGPoint(
            x: xPosition(for: band.frequencyHz, width: size.width),
            y: yPosition(for: band.gainDB, height: size.height)
        )
        return Text("\(index + 1)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 16, height: 16)
            .background(Circle().fill(Color.teal.opacity(0.7)))
            .position(point)
            .allowsHitTesting(false)
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

/// Double-click a labeled readout (`F: …`) to type a new value.
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

/// Double-click a numeric readout to edit; Return / focus loss commits.
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
