import SwiftUI

struct TestEQView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Test EQ")
                .font(.headline)

            Text("One peaking band at \(Int(model.testEQFrequencyHz)) Hz (Q \(String(format: "%.2f", model.testEQQ))).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !model.isPassThroughEnabled {
                Text("Enable Pass-through to hear this EQ. Matching-only stays dry.")
                    .foregroundStyle(.secondary)
            } else {
                Text(model.eqStatusText)
                    .foregroundStyle(model.isEQActive ? Color.primary : Color.secondary)
            }

            HStack {
                Text("Gain")
                Slider(
                    value: Binding(
                        get: { model.eqGainDB },
                        set: { model.setEQGainDB($0) }
                    ),
                    in: -12...12,
                    step: 0.5
                )
                .disabled(!model.isPassThroughEnabled)
                Text(String(format: "%+.1f dB", model.eqGainDB))
                    .monospacedDigit()
                    .frame(width: 72, alignment: .trailing)
            }

            Button("Bypass (0 dB)") {
                model.setEQGainDB(0)
            }
            .disabled(!model.isPassThroughEnabled || abs(model.eqGainDB) < PeakingBiquad.bypassThresholdDB)

            Text("When gain ≠ 0 dB the path is no longer bit-perfect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}
