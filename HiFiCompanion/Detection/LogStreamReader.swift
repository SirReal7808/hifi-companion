import Foundation

/// Spawns `/usr/bin/log stream` and yields lines matching Music / Core Audio / Core Media playback.
final class LogStreamReader: @unchecked Sendable {
    private var process: Process?
    private var pipe: Pipe?
    private let queue = DispatchQueue(label: "com.hificompanion.logstream")

    /// Predicate covering the same subsystems LosslessSwitcher watches.
    static let predicate =
        #"(subsystem == "com.apple.coreaudio") OR (subsystem == "com.apple.coremedia") OR (processImagePath CONTAINS[c] "Music" AND composedMessage CONTAINS[c] "audioCapabilities")"#

    func start(onLine: @escaping @Sendable (String) -> Void) {
        stop()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream",
            "--style", "compact",
            "--predicate", Self.predicate
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        self.process = process
        self.pipe = pipe

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                chunk.split(whereSeparator: \.isNewline).forEach { line in
                    onLine(String(line))
                }
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.pipe = nil
        }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        pipe = nil
    }

    deinit {
        stop()
    }
}
