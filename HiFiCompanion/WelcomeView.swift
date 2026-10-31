import SwiftUI

/// First-run explainer, shown before the System Audio Recording prompt
/// (docs/redesign-0.3.md → First run).
struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text("Welcome to HiFi Companion")
                    .font(.system(size: 20, weight: .semibold))
            }

            Text("To equalize what you hear, macOS will ask for **System Audio Recording**. This lets HiFi Companion process other apps' sound on its way to your DAC.")
            Text("It is not the microphone, and nothing is recorded or saved.")
            Text("You can turn the equalizer off at any time; when it's off, HiFi Companion stays out of the signal path.")
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Not Now") {
                    model.finishWelcome(turnOnEqualizer: false)
                }
                .keyboardShortcut(.cancelAction)
                Button("Turn On Equalizer") {
                    model.finishWelcome(turnOnEqualizer: true)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.outputDevice == nil)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 440)
    }
}
