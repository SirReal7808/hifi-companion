import Foundation

/// `--null-test`: plays a soft 24-bit test file through a flat-equalizer tap on the current macOS
/// output and checks the samples handed to the DAC are bit-exact — once with the tap's drift
/// compensation on (normal use), once with bands at 0 dB, once with drift compensation off.
/// Runs instead of the app's services (no SB matching, no user curve); quit the normal app first
/// (`scripts/null-test.sh` does). Audible: ~3 s of −48 dBFS noise, three times.
@MainActor
enum NullTestRunner {
    /// One measured pass: tap drift compensation, and whether to load bands set to 0 dB.
    private struct Pass {
        var label: String
        var driftCompensation: Bool
        var zeroDBBands: Bool
    }

    private static let passes = [
        Pass(label: "flat, drift on", driftCompensation: true, zeroDBBands: false),
        Pass(label: "4 bands at 0 dB, drift on", driftCompensation: true, zeroDBBands: true),
        Pass(label: "flat, drift off", driftCompensation: false, zeroDBBands: false)
    ]

    /// Runs every pass; each line is printed and also appended to `reportPath` when given
    /// (stdout is lost when the script starts the app with `open`).
    static func run(reportPath: String?) async -> Bool {
        var lines: [String] = []
        func report(_ line: String) {
            print(line)
            lines.append(line)
            if let reportPath {
                try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
            }
        }

        let manager = AudioDeviceManager()
        guard let device = manager.defaultOutputDevice(),
              let format = manager.currentFormat(for: device.id)
        else {
            report("NULL_TEST: no output device")
            return false
        }
        let rate = format.sampleRate
        let channels = 2
        let ints = NullTest.referenceInt24(frames: Int(rate * 3), channels: channels, leadInFrames: Int(rate * 0.3))
        let reference = NullTest.float(fromInt24: ints)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hifi-companion-null-test.wav")
        do {
            try writeWAV24(ints, channels: channels, sampleRate: rate, to: url)
        } catch {
            report("NULL_TEST: could not write the test file: \(error)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: url) }
        report("NULL_TEST: output=\(device.name) format=\(Int(rate)) Hz / \(format.bitDepth)-bit")

        var allExact = true
        for pass in passes {
            let bridge = PassThroughBridge()
            bridge.tapDriftCompensation = pass.driftCompensation
            let recorder = NullTestRecorder(frames: Int(rate * 6))
            bridge.nullTestRecorder = recorder
            do {
                try bridge.start(outputDeviceID: device.id, outputDeviceUID: device.uid)
            } catch {
                report("NULL_TEST: [\(pass.label)] tap failed: \(error.localizedDescription)")
                return false
            }
            // A fresh bridge is flat (no bands, 0 dB output, not bypassed); optionally load
            // bands at 0 dB to cover the "audibly flat band" skip the app relies on.
            if pass.zeroDBBands {
                let bands = [100.0, 1_000, 5_000, 12_000].map {
                    EQBand(id: UUID(), enabled: true, filterType: .peaking, frequencyHz: $0, gainDB: 0, q: 1)
                }
                bridge.applyPEQ(bands: bands, outputGainDB: 0, bypass: false)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            await play(url)
            try? await Task.sleep(nanoseconds: 400_000_000)
            bridge.stop()

            let captured = recorder.samples(keepChannels: channels)
            let result = NullTest.compare(reference: reference, captured: captured, channels: channels)
            report(NullTest.summary(result, label: pass.label, sampleRate: recorder.sampleRate, channels: recorder.channels))
            allExact = allExact && result.isBitExact
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return allExact
    }

    /// `afplay` to the default output; returns when playback ends.
    private static func play(_ url: URL) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            process.arguments = [url.path]
            process.terminationHandler = { _ in done.resume() }
            do {
                try process.run()
            } catch {
                print("NULL_TEST: afplay failed: \(error)")
                done.resume()
            }
        }
    }

    /// Plain little-endian 24-bit PCM WAV (no converter in between).
    private static func writeWAV24(_ samples: [Int32], channels: Int, sampleRate: Double, to url: URL) throws {
        let bytesPerSample = 3
        let dataSize = samples.count * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1) // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(channels * bytesPerSample))
        u16(UInt16(channels * bytesPerSample))
        u16(24)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        for s in samples {
            let v = UInt32(bitPattern: s)
            data.append(UInt8(v & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
        }
        try data.write(to: url)
    }
}
