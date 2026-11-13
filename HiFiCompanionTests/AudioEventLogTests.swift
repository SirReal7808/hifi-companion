import XCTest

final class AudioEventLogTests: XCTestCase {
    func testContinuousCyclesAreNotDropouts() {
        var c = IOContinuity()
        XCTAssertEqual(c.observe(sampleTime: 1_000, hostSeconds: 10.000, frames: 512), .first)
        XCTAssertEqual(c.observe(sampleTime: 1_512, hostSeconds: 10.012, frames: 512), .continuous)
        XCTAssertEqual(c.observe(sampleTime: 2_024, hostSeconds: 10.023, frames: 256), .continuous)
        XCTAssertEqual(c.observe(sampleTime: 2_280, hostSeconds: 10.029, frames: 512), .continuous)
    }

    func testSkippedCycleInsideAStreamIsAGap() {
        var c = IOContinuity()
        _ = c.observe(sampleTime: 0, hostSeconds: 5.000, frames: 512)
        _ = c.observe(sampleTime: 512, hostSeconds: 5.012, frames: 512)
        // One buffer lost: sample time jumps 512 ahead while host time moved only ~2 buffers.
        XCTAssertEqual(c.observe(sampleTime: 1_536, hostSeconds: 5.035, frames: 512), .gap(frames: 512))
        XCTAssertEqual(c.observe(sampleTime: 2_048, hostSeconds: 5.046, frames: 512), .continuous)
    }

    func testRepeatedSamplesAreANegativeGap() {
        var c = IOContinuity()
        _ = c.observe(sampleTime: 4_096, hostSeconds: 1.0, frames: 512)
        XCTAssertEqual(c.observe(sampleTime: 4_352, hostSeconds: 1.01, frames: 512), .gap(frames: -256))
    }

    func testPauseThenPlayIsAResumeNotADropout() {
        var c = IOContinuity()
        _ = c.observe(sampleTime: 0, hostSeconds: 100, frames: 512)
        XCTAssertEqual(c.observe(sampleTime: 900_000, hostSeconds: 112.5, frames: 512), .resumed(afterSeconds: 12.5))
        XCTAssertEqual(c.observe(sampleTime: 900_512, hostSeconds: 112.512, frames: 512), .continuous)
    }

    func testQuickClockResetIsAResumeNotADropout() {
        var c = IOContinuity()
        _ = c.observe(sampleTime: 5_000_000, hostSeconds: 50.0, frames: 512)
        guard case .resumed = c.observe(sampleTime: 0, hostSeconds: 50.1, frames: 512) else {
            return XCTFail("a clock reset must not count as a dropout")
        }
        XCTAssertEqual(c.observe(sampleTime: 512, hostSeconds: 50.112, frames: 512), .continuous)
    }

    func testFaultsExcludeSlowCyclesAndResumes() {
        var counts = IOGlitchCounts()
        counts.slowCycles = 7
        counts.resumes = 3
        XCTAssertEqual(counts.faults, 0)
        counts.outputGaps = 1
        counts.overloads = 2
        counts.shortInputs = 1
        XCTAssertEqual(counts.faults, 4)
    }

    func testLogLineHasMillisecondLocalTime() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_793_473_243.512) // 2026-10-31 19:00:43.512 UTC
        XCTAssertEqual(AudioEventLog.line("Tap started", date: date, timeZone: utc), "2026-10-31 19:00:43.512  Tap started\n")
    }

    func testWritesAppendAndRotateInATempDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AudioEventLog(directory: dir, enabled: true, defaults: Self.scratchDefaults())
        log.isSaving = true
        log.write("one")
        log.write("two")
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("  one\n") && text.contains("  two\n"))

        try Data(count: AudioEventLog.maxBytes + 1).write(to: log.url)
        log.write("after rotation")
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("1").path))
        XCTAssertTrue(try String(contentsOf: log.url, encoding: .utf8).hasSuffix("  after rotation\n"))
    }

    func testSavingIsOffByDefaultAndWritesNothing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = Self.scratchDefaults()
        let log = AudioEventLog(directory: dir, enabled: true, defaults: defaults)
        XCTAssertFalse(log.isSaving)
        log.write("private")
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.url.path))

        log.isSaving = true
        XCTAssertTrue(AudioEventLog(directory: dir, enabled: true, defaults: defaults).isSaving, "the setting persists")
        log.isSaving = false
        XCTAssertFalse(AudioEventLog(directory: dir, enabled: true, defaults: defaults).isSaving)
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "AudioEventLogTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
