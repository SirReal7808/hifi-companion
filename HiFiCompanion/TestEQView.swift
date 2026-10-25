import SwiftUI

struct TestEQView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test EQ")
                .font(.headline)

            Text("1 kHz peaking (Q \(String(format: "%.2f", model.testEQQ))). Drag the slider — 0 dB is dry bypass.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isBridgeRunning {
                Text(model.testEQDisabledReason.isEmpty ? "Enable Pass-through first" : model.testEQDisabledReason)
                    .foregroundStyle(.secondary)
            } else {
                Text(model.eqStatusText)
                    .foregroundStyle(model.isEQActive ? Color.primary : Color.secondary)
                Text("Live on process-tap → DAC.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text("Gain")
                Slider(
                    value: Binding(
                        get: { model.eqGainDB },
                        set: { model.setEQGainDB($0) }
                    ),
                    in: -12...12,
                    step: 0.5
                )
                .disabled(!model.isBridgeRunning)
                Text(String(format: "%+.1f dB", model.eqGainDB))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }

            HStack {
                Button("Bypass (0 dB)") {
                    model.setEQGainDB(0)
                }
                .disabled(!model.isBridgeRunning || abs(model.eqGainDB) < PeakingBiquad.bypassThresholdDB)

                Spacer()

                Button("+6 dB") { model.setEQGainDB(6) }
                    .disabled(!model.isBridgeRunning)
                Button("+9 dB") { model.setEQGainDB(9) }
                    .disabled(!model.isBridgeRunning)
            }

            Text("Gain ≠ 0 dB means the path is not bit-perfect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
    }
}
