import Foundation

/// Phase-continuous sine for EQ Sweep mode. Frequency/amplitude updates never reset phase
/// (avoids zipper crackle while press-dragging the graph).
final class SweepOscillator: @unchecked Sendable {
    static let minLevelDB: Double = -20
    static let maxLevelDB: Double = 0
    static let defaultLevelDB: Double = -12

    private let lock = NSLock()
    private var sampleRate: Double = 48_000
    private var phase: Double = 0
    private var frequencyHz: Double = 1_000
    private var targetFrequencyHz: Double = 1_000
    private var amplitude: Double = 0
    private var targetAmplitude: Double = 0
    private var levelDB: Double = SweepOscillator.defaultLevelDB
    private var wantedOn = false

    /// True between press and release (not during the release fade).
    var isPressed: Bool {
        lock.lock(); defer { lock.unlock() }
        return wantedOn
    }

    var isAudible: Bool {
        lock.lock(); defer { lock.unlock() }
        return wantedOn || amplitude > 1e-5
    }

    func configure(sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        self.sampleRate = max(sampleRate, 1)
    }

    func setLevelDB(_ db: Double) {
        lock.lock()
        defer { lock.unlock() }
        levelDB = Self.clampLevelDB(db)
        if wantedOn {
            targetAmplitude = Self.linearGain(forDB: levelDB)
        }
    }

    /// Begin or continue press-drag at `hz` (phase preserved).
    func press(atHz hz: Double) {
        lock.lock()
        defer { lock.unlock() }
        let clamped = min(EQBand.maxFrequencyHz, max(EQBand.minFrequencyHz, hz))
        targetFrequencyHz = clamped
        if !wantedOn {
            frequencyHz = clamped
        }
        wantedOn = true
        targetAmplitude = Self.linearGain(forDB: levelDB)
    }

    func updateFrequency(atHz hz: Double) {
        lock.lock()
        defer { lock.unlock() }
        targetFrequencyHz = min(EQBand.maxFrequencyHz, max(EQBand.minFrequencyHz, hz))
    }

    /// Release: fade amp to 0; phase/freq kept for the next press.
    func release() {
        lock.lock()
        defer { lock.unlock() }
        wantedOn = false
        targetAmplitude = 0
    }

    func hardMute() {
        lock.lock()
        defer { lock.unlock() }
        wantedOn = false
        targetAmplitude = 0
        amplitude = 0
    }

    /// Write `frames` mono samples (overwrites `destination`).
    func renderMono(_ destination: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        var phase = self.phase
        var freq = self.frequencyHz
        var amp = self.amplitude
        let targetFreq = self.targetFrequencyHz
        let targetAmp = self.targetAmplitude
        let rate = self.sampleRate
        let ampCoeff = 1.0 - exp(-1.0 / (rate * 0.008))
        let freqCoeff = 1.0 - exp(-1.0 / (rate * 0.004))
        lock.unlock()

        let twoPi = 2.0 * Double.pi
        for i in 0..<frames {
            freq += (targetFreq - freq) * freqCoeff
            amp += (targetAmp - amp) * ampCoeff
            destination[i] = Float(amp * sin(phase))
            phase += twoPi * freq / rate
            if phase >= twoPi {
                phase = phase.truncatingRemainder(dividingBy: twoPi)
            }
        }

        lock.lock()
        self.phase = phase
        self.frequencyHz = freq
        self.amplitude = amp
        lock.unlock()
    }

    static func linearGain(forDB db: Double) -> Double {
        pow(10.0, db / 20.0)
    }

    static func clampLevelDB(_ db: Double) -> Double {
        min(maxLevelDB, max(minLevelDB, db))
    }
}
