import Foundation

enum FormatParser {
    /// Parse a line from `log stream` for Apple Music / Core Audio / Core Media format hints.
    static func parse(line: String) -> AudioFormatInfo? {
        if let info = parseALACInputFormat(line) {
            return info
        }
        if let info = parseAudioCapabilities(line) {
            return info
        }
        if let info = parseAudioQueue(line) {
            return info
        }
        return nil
    }

    /// `ACAppleLosslessDecoder ... Input format: 2 ch, 192000 Hz, alac ... from 24-bit source`
    private static func parseALACInputFormat(_ line: String) -> AudioFormatInfo? {
        guard line.contains("ACAppleLosslessDecoder"),
              line.contains("Input format:")
        else { return nil }

        guard let rate = captureDouble(
            in: line,
            pattern: #"ch,\s*([0-9]+(?:\.[0-9]+)?)\s*Hz"#
        ) else { return nil }

        let bitDepth: Int
        if let bits = captureInt(in: line, pattern: #"from\s+([0-9]+)-bit source"#) {
            bitDepth = bits
        } else if line.contains("alac") || line.contains("qlac") {
            bitDepth = 24
        } else {
            return nil
        }

        return AudioFormatInfo(sampleRate: rate, bitDepth: bitDepth)
    }

    /// `audioCapabilities: ... sdBitDepth = 16 bit, asbdSampleRate = 44.1 kHz`
    private static func parseAudioCapabilities(_ line: String) -> AudioFormatInfo? {
        guard line.contains("audioCapabilities:") || line.contains("asbdSampleRate") else {
            return nil
        }

        guard let rateKHz = captureDouble(
            in: line,
            pattern: #"asbdSampleRate\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*kHz"#
        ) else { return nil }

        let bitDepth: Int
        if let bits = captureInt(in: line, pattern: #"sdBitDepth\s*=\s*([0-9]+)\s*bit"#) {
            bitDepth = bits
        } else if line.contains("sdBitRate") {
            bitDepth = 16
        } else {
            return nil
        }

        return AudioFormatInfo(sampleRate: rateKHz * 1000.0, bitDepth: bitDepth)
    }

    /// `Creating AudioQueue with format:'qlac' ... sampleRate:192000`
    private static func parseAudioQueue(_ line: String) -> AudioFormatInfo? {
        guard line.contains("Creating AudioQueue") || line.contains("subaq_buildCAAudioQueue") else {
            return nil
        }
        guard let rate = captureDouble(
            in: line,
            pattern: #"sampleRate:([0-9]+(?:\.[0-9]+)?)"#
        ) else { return nil }

        // Core Media queue lines often omit bit depth; assume 24 for lossless-looking rates.
        let bitDepth = 24
        return AudioFormatInfo(sampleRate: rate, bitDepth: bitDepth)
    }

    private static func captureDouble(in text: String, pattern: String) -> Double? {
        guard let match = firstMatch(in: text, pattern: pattern),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Double(text[range])
    }

    private static func captureInt(in text: String, pattern: String) -> Int? {
        guard let match = firstMatch(in: text, pattern: pattern),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }

    private static func firstMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range)
    }
}
