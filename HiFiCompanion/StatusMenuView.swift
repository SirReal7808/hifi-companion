import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Signal path (interim text form; the R5 panel shows a colored dot and hover detail).
        Text("● \(model.signalPath.state.label) — \(model.signalPath.summary)")
        Text(model.signalPath.detail)

        Text(model.pathStatusText)
        if model.isBridgeRunning {
            Text(model.eqStatusText)
            Text(model.signalMeterText.isEmpty ? "Signal: …" : model.signalMeterText)
        }

        Text("Track: \(model.detectedFormat?.menuDescription ?? "—")")
        Text("DAC: \(model.deviceFormat?.menuDescription ?? "—")")
        if let error = model.lastError {
            Text(error)
                .foregroundStyle(.red)
        }

        Divider()

        Button {
            // Defer past MenuBarExtra dismissal — synchronous MainActor work here caused SIGBUS.
            DispatchQueue.main.async {
                model.togglePassThrough()
            }
        } label: {
            Text(equalizerLabel)
        }
        .disabled(model.outputDevice == nil && !model.isPassThroughEnabled)
        .help(AppModel.passThroughMenuNote)

        Button {
            DispatchQueue.main.async {
                model.setAppleMusicModeEnabled(!model.isAppleMusicModeEnabled)
            }
        } label: {
            Text(model.isAppleMusicModeEnabled ? "Apple Music Mode ✓" : "Apple Music Mode")
        }
        .help(AppModel.appleMusicModeMenuNote)

        Button {
            // Defer past menu dismissal; open a floating NSPanel (openWindow is unreliable
            // from MenuBarExtra `.menu` on LSUIElement apps).
            DispatchQueue.main.async {
                model.showPEQPanel()
            }
        } label: {
            if model.isBridgeRunning {
                Text("Open Equalizer…")
            } else {
                Text("Open Equalizer… (\(model.testEQDisabledReason))")
            }
        }
        .keyboardShortcut("e")
        .disabled(!model.isBridgeRunning)

        Button {
            DispatchQueue.main.async {
                model.playTestToneToDAC()
            }
        } label: {
            Text(model.isBridgeRunning ? "Test tone" : "Test tone (Parametric Equalizer off)")
        }
        .disabled(!model.isBridgeRunning)

        Divider()

        Text("Output: \(model.outputDevice?.name ?? "none")")

        Button {
            DispatchQueue.main.async {
                model.selectOutput(nil)
            }
        } label: {
            if model.preferredOutputUID == nil {
                Text("System Default ✓")
            } else {
                Text("System Default")
            }
        }

        ForEach(model.devices) { device in
            Button {
                DispatchQueue.main.async {
                    model.selectOutput(device)
                }
            } label: {
                if model.isPreferredOutput(device) {
                    Text("\(device.name) ✓")
                } else {
                    Text(device.name)
                }
            }
        }

        Divider()

        Menu("Appearance") {
            ForEach(AppearancePreference.allCases) { pref in
                Button {
                    model.setAppearancePreference(pref)
                } label: {
                    if model.appearancePreference == pref {
                        Text("\(pref.menuLabel) ✓")
                    } else {
                        Text(pref.menuLabel)
                    }
                }
            }
        }

        Divider()

        Button("Quit HiFi Companion") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var equalizerLabel: String {
        if model.isPassThroughEnabled && model.isBridgeRunning {
            return "Parametric Equalizer ✓"
        }
        if model.isPassThroughEnabled, let owner = model.exclusiveOutputOwner {
            return "Parametric Equalizer — Unavailable (\(owner) exclusive)"
        }
        if model.isPassThroughEnabled {
            return "Parametric Equalizer ✓ (waiting)"
        }
        if model.outputDevice == nil {
            return "Parametric Equalizer (no hardware output)"
        }
        return "Parametric Equalizer"
    }
}
