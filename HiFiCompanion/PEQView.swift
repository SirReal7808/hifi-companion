import SwiftUI

struct PEQView: View {
    @EnvironmentObject private var model: AppModel

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
                Text("Output gain is above the safe ceiling (risk of clipping). Lower output gain or reduce band boosts.")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Output")
                Slider(
                    value: Binding(
                        get: { model.peqOutputGainDB },
                        set: { model.setPEQOutputGainDB($0) }
                    ),
                    in: -24...6,
                    step: 0.5
                )
                .disabled(!model.isBridgeRunning)
                Text(String(format: "%+.1f dB", model.peqOutputGainDB))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
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
                Button("Reset flat") {
                    model.resetPEQFlat()
                }
                .disabled(!model.isBridgeRunning)
                Spacer()
                Text("Bypass skips biquads only; output gain still applies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520)
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
                Text(String(format: "B%d  %.0f Hz", index + 1, band.frequencyHz))
                    .frame(width: 100, alignment: .leading)
                    .monospacedDigit()
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
                Text(String(format: "%.0f", band.frequencyHz))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
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
                Text(String(format: "%+.1f", band.gainDB))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
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
                    step: 0.05
                )
                Text(String(format: "%.2f", band.q))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .disabled(!model.isBridgeRunning)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }
}
