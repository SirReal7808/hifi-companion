import AVFoundation
import Foundation

/// RBJ cookbook peaking EQ with Double-precision coefficients, Float sample processing.
final class PeakingBiquad: @unchecked Sendable {
    static let defaultFrequency: Double = 1_000
    static let defaultQ: Double = 1.41
    /// Treat |gain| below this as bypass (audibly identical to dry).
    static let bypassThresholdDB: Double = 0.05

    private let lock = NSLock()
    private var sampleRate: Double = 48_000
    private var frequency: Double = PeakingBiquad.defaultFrequency
    private var q: Double = PeakingBiquad.defaultQ
    private var gainDB: Double = 0
    private var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1: [Double] = []
    private var x2: [Double] = []
    private var y1: [Double] = []
    private var y2: [Double] = []

    var isBypassed: Bool {
        lock.lock(); defer { lock.unlock() }
        return abs(gainDB) < Self.bypassThresholdDB
    }

    var currentGainDB: Double {
        lock.lock(); defer { lock.unlock() }
        return gainDB
    }

    func configure(sampleRate: Double, frequency: Double = PeakingBiquad.defaultFrequency, q: Double = PeakingBiquad.defaultQ) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = max(sampleRate, 1)
        self.frequency = frequency
        self.q = max(q, 0.1)
        recalculateLocked()
        resetStateLocked(channelCount: max(x1.count, 2))
    }

    func setGainDB(_ gainDB: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.gainDB = gainDB
        recalculateLocked()
    }

    func resetState(channelCount: Int) {
        lock.lock()
        defer { lock.unlock() }
        resetStateLocked(channelCount: channelCount)
    }

    /// Process an AVAudioPCMBuffer in place (float non-interleaved or interleaved).
    func processInPlace(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        guard channels > 0, frames > 0 else { return }

        if let channelsPointer = buffer.floatChannelData {
            for ch in 0..<channels {
                processChannel(channelsPointer[ch], frames: frames, channel: ch)
            }
            return
        }

        guard buffer.format.isInterleaved,
              let block = buffer.audioBufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self)
        else { return }
        processInterleaved(block, frames: frames, channels: channels)
    }

    /// Realtime-safe: process interleaved float PCM in place (no heap allocation).
    func processInterleaved(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, channels > 0 else { return }
        if x1.count != channels {
            resetStateLocked(channelCount: channels)
        }
        if abs(gainDB) < Self.bypassThresholdDB { return }

        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        for i in 0..<frames {
            for ch in 0..<channels {
                let index = i * channels + ch
                let x0 = Double(samples[index])
                let y0 = b0 * x0 + b1 * x1[ch] + b2 * x2[ch] - a1 * y1[ch] - a2 * y2[ch]
                x2[ch] = x1[ch]; x1[ch] = x0
                y2[ch] = y1[ch]; y1[ch] = y0
                samples[index] = Float(y0)
            }
        }
    }

    /// Realtime-safe: process one planar float channel in place.
    func processChannel(_ samples: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard frames > 0, channel >= 0 else { return }
        if channel >= x1.count {
            resetStateLocked(channelCount: channel + 1)
        }
        if abs(gainDB) < Self.bypassThresholdDB { return }

        let b0 = self.b0, b1 = self.b1, b2 = self.b2, a1 = self.a1, a2 = self.a2
        var x1v = x1[channel], x2v = x2[channel], y1v = y1[channel], y2v = y2[channel]
        for i in 0..<frames {
            let x0 = Double(samples[i])
            let y0 = b0 * x0 + b1 * x1v + b2 * x2v - a1 * y1v - a2 * y2v
            x2v = x1v; x1v = x0
            y2v = y1v; y1v = y0
            samples[i] = Float(y0)
        }
        x1[channel] = x1v; x2[channel] = x2v; y1[channel] = y1v; y2[channel] = y2v
    }

    /// Test helper: magnitude response in dB at `hz` (analytical from coeffs).
    func magnitudeDB(atHz hz: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let w = 2.0 * Double.pi * hz / sampleRate
        let z1r = cos(w), z1i = -sin(w)
        let z2r = cos(2 * w), z2i = -sin(2 * w)
        let numR = b0 + b1 * z1r + b2 * z2r
        let numI = b1 * z1i + b2 * z2i
        let denR = 1.0 + a1 * z1r + a2 * z2r
        let denI = a1 * z1i + a2 * z2i
        let denMag2 = denR * denR + denI * denI
        guard denMag2 > 0 else { return 0 }
        let mag2 = (numR * numR + numI * numI) / denMag2
        return 10.0 * log10(max(mag2, 1e-30))
    }

    private func resetStateLocked(channelCount: Int) {
        let count = max(channelCount, 1)
        x1 = Array(repeating: 0, count: count)
        x2 = Array(repeating: 0, count: count)
        y1 = Array(repeating: 0, count: count)
        y2 = Array(repeating: 0, count: count)
    }

    private func recalculateLocked() {
        // Robert Bristow-Johnson peaking EQ (Audio EQ Cookbook).
        let A = pow(10.0, gainDB / 40.0)
        let w0 = 2.0 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let sinw0 = sin(w0)
        let alpha = sinw0 / (2.0 * q)

        let b0 = 1.0 + alpha * A
        let b1 = -2.0 * cosw0
        let b2 = 1.0 - alpha * A
        let a0 = 1.0 + alpha / A
        let a1 = -2.0 * cosw0
        let a2 = 1.0 - alpha / A

        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }
}
