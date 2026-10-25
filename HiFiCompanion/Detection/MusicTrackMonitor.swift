import Foundation

/// Observes Apple Music / iTunes distributed player-info notifications for track changes.
final class MusicTrackMonitor {
    private var lastTrackSignature: String?
    private var observers: [NSObjectProtocol] = []
    private let onTrackChanged: () -> Void

    init(onTrackChanged: @escaping () -> Void) {
        self.onTrackChanged = onTrackChanged
    }

    func start() {
        stop()
        let center = DistributedNotificationCenter.default()
        let names = [
            Notification.Name("com.apple.Music.playerInfo"),
            Notification.Name("com.apple.iTunes.playerInfo")
        ]
        for name in names {
            let token = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handle(notification)
            }
            observers.append(token)
        }
    }

    func stop() {
        let center = DistributedNotificationCenter.default()
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
        lastTrackSignature = nil
    }

    private func handle(_ notification: Notification) {
        guard let info = notification.userInfo else { return }
        let persistentID: String?
        if let id = info["PersistentID"] as? Int {
            persistentID = String(id)
        } else if let id = info["PersistentID"] as? String {
            persistentID = id
        } else {
            persistentID = nil
        }
        let name = (info["Name"] as? String) ?? (info["Title"] as? String)
        let signature = [persistentID, name].compactMap { $0 }.joined(separator: "|")
        guard !signature.isEmpty else { return }
        if signature != lastTrackSignature {
            lastTrackSignature = signature
            onTrackChanged()
        }
    }
}
