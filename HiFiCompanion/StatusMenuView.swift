import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(AppModel.appleMusicModeMenuNote)
        Text(AppModel.passThroughMenuNote)

        Text(model.pathStatusText)
        Text(model.matchingStatusText)
        if model.isBridgeRunning {
            Text(model.eqStatusText)
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
        .disabled(!model.virtualDeviceAvailable && !model.isPassThroughEnabled)

        Button {
            DispatchQueue.main.async {
                openWindow(id: "test-eq")
            }
        } label: {
            if model.isBridgeRunning {
                Text("Test EQ…")
            } else {
                Text("Test EQ… (\(model.testEQDisabledReason))")
            }
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
        if model.virtualDeviceAvailable {
            return "Pass-through"
        }
        return "Pass-through (needs BlackHole 2ch)"
    }
}
