import SwiftUI

@main
struct HiFiCompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var appModel = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView()
                .environmentObject(appModel)
        } label: {
            // Placeholder until the logo exists; optional items from Settings → General.
            Text(appModel.menuBarTitle)
        }
        .menuBarExtraStyle(.window)
    }
}
