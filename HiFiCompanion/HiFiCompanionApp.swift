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
            Text(appModel.statusTitle)
        }
        .menuBarExtraStyle(.menu)

        Window("Test EQ", id: "test-eq") {
            TestEQView()
                .environmentObject(appModel)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 360, height: 220)
    }
}
