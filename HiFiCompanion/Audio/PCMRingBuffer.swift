import AVFoundation
import Foundation

/// Stereo float ring buffer for hopping BlackHole capture → DAC render (non-realtime producer / realtime consumer).
final class PCMRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var framesFilled = 0
    let channels: Int
    private let capacityFrames: Int

    init(capacityFrames: Int, channels: Int = 2) {
        self.channels = max(channels, 1)
        self.capacityFrames = max(capacityFrames, 2048)
        storage = [Float](repeating: 0, count: self.capacityFrames * self.channels)
    }

    var availableFrames: Int {
        lock.lock(); defer { lock.unlock() }
        return framesFilled
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        readIndex = 0
        writeIndex = 0
        framesFilled = 0
    }

    /// Write non-interleaved float channels.
    func write(nonInterleaved src: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, channelCount: Int) {
        guard frames > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let ch = min(channelCount, channels)
        for frame in 0..<frames {
            if framesFilled == capacityFrames {
                readIndex = (readIndex + 1) % capacityFrames
                framesFilled -= 1
            }
            let base = writeIndex * channels
            for c in 0..<channels {
                storage[base + c] = c < ch ? src[c][frame] : 0
            }
            writeIndex = (writeIndex + 1) % capacityFrames
            framesFilled += 1
        }
    }

    /// Fill non-interleaved float AudioBufferList; returns frames written (rest zeroed).
    @discardableResult
    func read(into abl: UnsafeMutableAudioBufferListPointer, frames: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let canRead = min(frames, framesFilled)
        for frame in 0..<canRead {
            let base = readIndex * channels
            for c in 0..<abl.count {
                guard let data = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                data[frame] = c < channels ? storage[base + c] : 0
            }
            readIndex = (readIndex + 1) % capacityFrames
            framesFilled -= 1
        }
        if canRead < frames {
            for c in 0..<abl.count {
                guard let data = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in canRead..<frames {
                    data[frame] = 0
                }
            }
        }
        return canRead
    }
}
