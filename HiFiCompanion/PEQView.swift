import SwiftUI

struct PEQView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("10-band PEQ")
                    .font(.headline)
                Spacer()
                Toggle("Bypass bands", isOn: Binding(
                    get: { model.peqBypass },
                    set: { model.setPEQBypass($0) }
                ))
                .disabled(!model.isBridgeRunning)
            }

            if !model.isBridgeRunning {
                Text(model.testEQDisabledReason.isEmpty ? "Enable Pass-through first" : model.testEQDisabledReason)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.eqStatusText)
                    .foregroundStyle(model.isEQActive ? Color.primary : Color.secondary)
            }

            if model.peqClippingWarning {
                Text("Output + peak boost exceeds 0 dB (clipping risk). Lower output gain or reduce band boosts.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("Auto output gain", isOn: Binding(
                    get: { model.peqAutoOutputGain },
                    set: { model.setPEQAutoOutputGain($0) }
                ))
                .disabled(!model.isBridgeRunning)
                Toggle("Bypass gain match", isOn: Binding(
                    get: { model.peqBypassGainMatch },
                    set: { model.setPEQBypassGainMatch($0) }
                ))
                .disabled(!model.isBridgeRunning)
            }

            HStack {
                Text("Output")
                Slider(
                    value: Binding(
                        get: { model.peqOutputGainDB },
                        set: { model.setPEQOutputGainDB($0) }
                    ),
                    in: PEQHeadroom.minOutputGainDB...6,
                    step: 0.5
                )
                .disabled(!model.isBridgeRunning || model.peqAutoOutputGain)
                EditableNumberField(
                    value: model.peqOutputGainDB,
                    format: "%+.1f",
                    width: 72,
                    disabled: !model.isBridgeRunning
                ) { model.setPEQOutputGainDB($0) }
                Text("dB")
                    .foregroundStyle(.secondary)
                Button("Set safe") {
                    model.setPEQOutputGainToSafe()
                }
                .disabled(!model.isBridgeRunning)
            }

            Text(String(format: "Peak boost ≈ +%.1f dB · safe out ≤ %+.1f dB", model.peqPeakBoostDB, model.peqSafeCeilingDB))
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(model.peqBands.enumerated()), id: \.element.id) { index, band in
                        bandRow(index: index, band: band)
                    }
                }
            }
            .frame(maxHeight: 420)

            HStack {
                Button("Reset") {
                    confirmReset = true
                }
                .disabled(!model.isBridgeRunning)
                Spacer()
                Text(model.peqBypassGainMatch
                     ? "Bypass skips biquads; output gain still applies."
                     : "Bypass is true dry unity (no output gain).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 540)
        .confirmationDialog("Reset EQ bands?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                model.resetPEQFlat()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func bandRow(index: Int, band: EQBand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("B\(index + 1)", isOn: Binding(
                    get: { band.enabled },
                    set: { enabled in
                        model.updatePEQBand(id: band.id) { $0.enabled = enabled }
                    }
                ))
                .labelsHidden()
                Text(String(format: "B%d", index + 1))
                    .frame(width: 28, alignment: .leading)
                Spacer()
                Text("peaking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("F")
                Slider(
                    value: Binding(
                        get: { log10(band.frequencyHz) },
                        set: { logF in
                            model.updatePEQBand(id: band.id) {
                                $0.frequencyHz = pow(10, logF)
                            }
                        }
                    ),
                    in: log10(EQBand.minFrequencyHz)...log10(EQBand.maxFrequencyHz)
                )
                EditableNumberField(
                    value: band.frequencyHz,
                    format: "%.0f",
                    width: 56,
                    disabled: !model.isBridgeRunning
                ) { hz in
                    model.updatePEQBand(id: band.id) { $0.frequencyHz = hz }
                }
                Text("Hz")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("G")
                Slider(
                    value: Binding(
                        get: { band.gainDB },
                        set: { gain in
                            model.updatePEQBand(id: band.id) { $0.gainDB = gain }
                        }
                    ),
                    in: EQBand.minGainDB...EQBand.maxGainDB,
                    step: 0.5
                )
                EditableNumberField(
                    value: band.gainDB,
                    format: "%+.1f",
                    width: 56,
                    disabled: !model.isBridgeRunning
                ) { gain in
                    model.updatePEQBand(id: band.id) { $0.gainDB = gain }
                }
                Text("dB")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Q")
                Slider(
                    value: Binding(
                        get: { band.q },
                        set: { q in
                            model.updatePEQBand(id: band.id) { $0.q = q }
                        }
                    ),
                    in: EQBand.minQ...EQBand.maxQ,
                    step: 0.1
                )
                EditableNumberField(
                    value: band.q,
                    format: "%.1f",
                    width: 56,
                    disabled: !model.isBridgeRunning
                ) { q in
                    model.updatePEQBand(id: band.id) { $0.q = q }
                }
            }
        }
        .disabled(!model.isBridgeRunning)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}

/// Double-click a numeric readout to edit; Return / focus loss commits.
private struct EditableNumberField: View {
    let value: Double
    let format: String
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
                Text(String(format: format, value))
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
        guard let parsed = Double(cleaned) else { return }
        onCommit(parsed)
    }
}
