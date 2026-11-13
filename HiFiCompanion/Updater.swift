import Combine
import Sparkle
import SwiftUI

/// Sparkle 2 auto-update (docs/releases.md → Updates). The feed (`SUFeedURL`) and the
/// EdDSA public key (`SUPublicEDKey`) live in Info.plist; updates are signed with the
/// private key in the login keychain when a release is cut.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheckForUpdates = false
    @Published var automaticallyChecks: Bool {
        didSet {
            // Write only real user changes: an explicit write counts as the user's answer and
            // would skip Sparkle's "check automatically?" prompt.
            guard automaticallyChecks != controller.updater.automaticallyChecksForUpdates else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Starts Sparkle; called once at a normal launch (not for tests, screenshots or the null test).
    func start() {
        controller.startUpdater()
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        // A menu-bar (LSUIElement) app must come forward or Sparkle's window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
