import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(AppModel.appleMusicModeMenuNote)
        Text(AppModel.passThroughMenuNote)

        Text(model.pathStatusText)
        Text(model.matchingStatusText)
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
            HStack {
                Text(passThroughLabel)
                if model.isPassThroughEnabled && model.isBridgeRunning {
                    Spacer(minLength: 8)
                    Text("On")
                }
            }
        }
        .disabled(model.pinnedDeviceUID == nil && !model.isPassThroughEnabled)

        Button {
            // Defer past menu dismissal; open a floating NSPanel (openWindow is unreliable
            // from MenuBarExtra `.menu` on LSUIElement apps).
            DispatchQueue.main.async {
                model.showPEQPanel()
            }
        } label: {
            if model.isBridgeRunning {
                Text("PEQ…")
            } else {
                Text("PEQ… (\(model.testEQDisabledReason))")
            }
        }
        .disabled(!model.isBridgeRunning)

        Button {
            DispatchQueue.main.async {
                model.playTestToneToDAC()
            }
        } label: {
            Text(model.isBridgeRunning ? "Test tone to DAC" : "Test tone to DAC (Enable Pass-through first)")
        }
        .disabled(!model.isBridgeRunning)

        Divider()

        Button {
            DispatchQueue.main.async {
                model.pinDevice(nil)
            }
        } label: {
            if model.pinnedDeviceUID == nil {
                Text("System Default ✓")
            } else {
                Text("System Default")
            }
        }

        ForEach(model.devices) { device in
            Button {
                DispatchQueue.main.async {
                    model.pinDevice(device)
                }
            } label: {
                if model.isPinned(device) {
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

    private var passThroughLabel: String {
        if model.isPassThroughEnabled && model.isBridgeRunning {
            return "Pass-through ✓"
        }
        if model.isPassThroughEnabled {
            return "Pass-through (error)"
        }
        if model.pinnedDeviceUID == nil {
            return "Pass-through (pin a DAC first)"
        }
        return "Pass-through"
    }
}
