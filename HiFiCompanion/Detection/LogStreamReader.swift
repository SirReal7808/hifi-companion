import Foundation
import os.log

/// Spawns `/usr/bin/log stream` and yields lines matching Music / Core Audio / Core Media playback.
/// Restarts `log` with backoff if it exits while still wanted.
final class LogStreamReader: @unchecked Sendable {
    private let log = Logger(subsystem: "com.hificompanion.app", category: "LogStreamReader")
    /// Serializes all state below (start / stop, pipe reads, restarts).
    private let queue = DispatchQueue(label: "com.hificompanion.logstream")
    private var process: Process?
    private var pipe: Pipe?
    private var splitter = LineSplitter()
    private var onLine: (@Sendable (String) -> Void)?
    private var wantsRunning = false
    private var restartDelay: TimeInterval = LogStreamReader.minRestartDelay

    private static let minRestartDelay: TimeInterval = 1
    private static let maxRestartDelay: TimeInterval = 30

    /// Predicate covering the same subsystems LosslessSwitcher watches.
    static let predicate =
        #"(subsystem == "com.apple.coreaudio") OR (subsystem == "com.apple.coremedia") OR (processImagePath CONTAINS[c] "Music" AND composedMessage CONTAINS[c] "audioCapabilities")"#

    func start(onLine: @escaping @Sendable (String) -> Void) {
        queue.sync {
            stopLocked()
            self.onLine = onLine
            wantsRunning = true
            restartDelay = Self.minRestartDelay
            launchLocked()
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    deinit {
        // No other reference exists by now; never `queue.sync` here (could run on `queue`).
        stopLocked()
    }

    // MARK: - Locked (on `queue`)

    private func launchLocked() {
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
        splitter.reset()

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async {
                self?.consumeLocked(data, from: process)
            }
        }
        process.terminationHandler = { [weak self] exited in
            self?.queue.async {
                self?.handleTerminationLocked(of: exited)
            }
        }

        do {
            try process.run()
            self.process = process
            self.pipe = pipe
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            log.error("log stream failed to start: \(error.localizedDescription, privacy: .public)")
            scheduleRestartLocked()
        }
    }

    private func consumeLocked(_ data: Data, from source: Process) {
        guard source === process, let onLine else { return }
        let lines = splitter.append(data)
        if !lines.isEmpty {
            restartDelay = Self.minRestartDelay
        }
        lines.forEach(onLine)
    }

    private func handleTerminationLocked(of exited: Process) {
        guard wantsRunning, exited === process else { return }
        log.error("log stream exited (status \(exited.terminationStatus, privacy: .public)); restarting")
        pipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        pipe = nil
        scheduleRestartLocked()
    }

    private func scheduleRestartLocked() {
        guard wantsRunning else { return }
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, Self.maxRestartDelay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.wantsRunning, self.process == nil else { return }
            self.launchLocked()
        }
    }

    private func stopLocked() {
        wantsRunning = false
        onLine = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
            }
        }
        process = nil
        pipe = nil
        splitter.reset()
    }
}
