import Foundation

/// Detects Apple Music track format via `log stream`, with AppleScript sample-rate fallback.
final class MusicFormatDetector: @unchecked Sendable {
    private let reader = LogStreamReader()
    private var lastEmitted: FormatDetection?
    private let lock = NSLock()
    private var fallbackTimer: DispatchSourceTimer?

    func detections() -> AsyncStream<FormatDetection> {
        AsyncStream { continuation in
            let reader = self.reader

            reader.start { [weak self] line in
                guard let self else { return }
                guard let parsed = FormatParser.parse(line: line) else { return }
                self.emit(parsed, to: continuation)
            }

            self.startAppleScriptFallback(continuation: continuation)

            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        reader.stop()
        fallbackTimer?.cancel()
        fallbackTimer = nil
    }

    private func emit(_ detection: FormatDetection, to continuation: AsyncStream<FormatDetection>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastEmitted,
           last.format == detection.format,
           last.source == detection.source {
            return
        }
        lastEmitted = detection
        continuation.yield(detection)
    }

    private func startAppleScriptFallback(continuation: AsyncStream<FormatDetection>.Continuation) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 4, repeating: 8)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alreadyHaveLogDetection = self.lastEmitted != nil
            self.lock.unlock()
            // Only use AppleScript when log stream has not produced a format yet.
            guard let rate = AppleScriptFallback.currentTrackSampleRate() else { return }
            if alreadyHaveLogDetection {
                return
            }
            let detection = FormatDetection(
                format: AudioFormatInfo(sampleRate: rate, bitDepth: 24),
                source: .appleScript,
                detectedAt: Date()
            )
            self.emit(detection, to: continuation)
        }
        fallbackTimer = timer
        timer.resume()
    }
}
