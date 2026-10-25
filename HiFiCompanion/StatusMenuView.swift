import SwiftUI

struct StatusMenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(AppModel.appleMusicModeMenuNote)

        Text(model.matchingStatusText)

        Text("Track: \(model.detectedFormat?.menuDescription ?? "—")")
        Text("DAC: \(model.deviceFormat?.menuDescription ?? "—")")
        if let error = model.lastError {
            Text(error)
        }

        Divider()

        Button {
            model.pinDevice(nil)
        } label: {
            if model.pinnedDeviceUID == nil {
                Text("System Default ✓")
            } else {
                Text("System Default")
            }
        }

        ForEach(model.devices) { device in
            Button {
                model.pinDevice(device)
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
}
