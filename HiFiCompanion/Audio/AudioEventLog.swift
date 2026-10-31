import Foundation

/// Plain-text audio event log for chasing dropouts: tap start / stop / rebuilds, rate and track
/// changes, and the IOProc continuity counters (`IOContinuity`). One line per event with a
/// millisecond wall-clock time, so "a hiccup in the middle of a track at 21:14" can be checked.
/// `~/Library/Logs/HiFiCompanion/audio-events.log`, rotated to `.1` at 2 MB. Never written from
/// the IOProc: the bridge polls its counters on its own queue.
final class AudioEventLog: @unchecked Sendable {
    static let shared = AudioEventLog()

    static let maxBytes = 2 * 1_024 * 1_024
    let url: URL
    private let queue = DispatchQueue(label: "com.hificompanion.audio-event-log", qos: .utility)
    private let enabled: Bool

    /// Off while hosting unit tests, so test runs never write to the user's log.
    init(directory: URL? = nil, enabled: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil) {
        let dir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/HiFiCompanion", isDirectory: true)
        url = dir.appendingPathComponent("audio-events.log")
        self.enabled = enabled
    }

    func write(_ message: String, date: Date = Date()) {
        guard enabled else { return }
        let line = Self.line(message, date: date)
        let url = self.url
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > Self.maxBytes {
                let old = url.appendingPathExtension("1")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                // Throwing API: the old write(_:) raised an ObjC exception (crash) on a full disk.
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Wait until queued lines are on disk (automation / tests).
    func flush() { queue.sync {} }

    /// `2026-10-31 21:14:03.512  message\n` in local time. Pure; unit-tested.
    static func line(_ message: String, date: Date, timeZone: TimeZone = .current) -> String {
        "\(timestamp(date, timeZone: timeZone))  \(message)\n"
    }

    static func timestamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0,
            (c.nanosecond ?? 0) / 1_000_000
        )
    }
}

/// Sample-time continuity of the aggregate IOProc. Pure; unit-tested.
///
/// Each cycle should start exactly where the previous one ended. A jump means samples were
/// skipped or repeated (a dropout). A long silence between cycles is not a dropout: the
/// aggregate only runs while a tapped app plays, so pause → play restarts it (`resumed`).
struct IOContinuity {
    enum Event: Equatable {
        case first
        case continuous
        /// Samples skipped (positive) or repeated (negative) within a running stream.
        case gap(frames: Double)
        /// IO stopped and restarted (pause / play); not a dropout.
        case resumed(afterSeconds: Double)
    }

    /// A pause shorter than this that still breaks continuity counts as a dropout.
    static let resumeThresholdSeconds = 0.5
    /// A backwards jump of more than this many buffers is a clock reset, not repeated samples.
    static let resetBuffers = 8.0

    private var expectedSampleTime: Double?
    private var lastHostSeconds: Double?

    mutating func observe(sampleTime: Double, hostSeconds: Double, frames: Int) -> Event {
        defer {
            expectedSampleTime = sampleTime + Double(frames)
            lastHostSeconds = hostSeconds
        }
        guard let expected = expectedSampleTime, let lastHost = lastHostSeconds else { return .first }
        let jump = sampleTime - expected
        if abs(jump) < 0.5 { return .continuous }
        let idle = hostSeconds - lastHost
        if idle >= Self.resumeThresholdSeconds { return .resumed(afterSeconds: idle) }
        // Sample time far behind where it was: the device clock was reset (IO restarted
        // quickly), not a few repeated samples.
        if jump < -Double(frames) * Self.resetBuffers { return .resumed(afterSeconds: idle) }
        return .gap(frames: jump)
    }
}

/// IOProc trouble since the tap started (Settings → Diagnostics and the event log).
struct IOGlitchCounts: Equatable {
    /// Input (tap) sample-time jumps inside a running stream.
    var inputGaps = 0
    /// Output (DAC) sample-time jumps inside a running stream.
    var outputGaps = 0
    /// Cycles where the tap delivered fewer frames than the output needed (tail zero-filled).
    var shortInputs = 0
    /// Cycles whose processing took more than half of the buffer's duration.
    var slowCycles = 0
    /// macOS processor-overload notifications on the aggregate.
    var overloads = 0
    /// Pause → play restarts (informational, not a fault).
    var resumes = 0
    /// Size of the latest gap on each side (frames; negative = repeated).
    var lastInputGapFrames: Double = 0
    var lastOutputGapFrames: Double = 0

    var faults: Int { inputGaps + outputGaps + shortInputs + overloads }
}
