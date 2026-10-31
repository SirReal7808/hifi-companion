import Foundation

/// What the user hears and how it gets to the output (docs/redesign-0.3.md → Signal path).
/// Observe-only and pure: built from device state, never touches audio. Unit-tested.
struct SignalPath: Equatable {
    enum State: Equatable {
        /// Nothing playing, or no hardware output.
        case idle
        /// One app, unprocessed, rates match (or an exclusive player). Not called "bit-perfect".
        case direct
        /// The Parametric Equalizer is processing the signal (intentionally colored).
        case equalizer
        /// Source and device sample rates differ.
        case resampled
        /// Several apps are playing at once (mixed by macOS).
        case mixed
        /// Bluetooth output: re-encoded with a lossy codec, so never "Direct".
        case bluetooth

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .direct: return "Direct"
            case .equalizer: return "Parametric Equalizer"
            case .resampled: return "Resampled"
            case .mixed: return "Mixed"
            case .bluetooth: return "Bluetooth (lossy)"
            }
        }
    }

    struct Source: Equatable {
        var appName: String
        /// Known for Apple Music (log detection); nil for other apps.
        var format: AudioFormatInfo?
    }

    enum EqualizerStage: Equatable {
        case off
        case processing
    }

    var state: State
    /// One line for the menu, e.g. `Apple Music → Parametric Equalizer → DX5 II`.
    var summary: String
    /// The full chain with formats, for the hover / Diagnostics view.
    var detail: String

    static let idle = SignalPath(state: .idle, summary: "No hardware output", detail: "No hardware output")

    static func make(
        sources: [Source],
        equalizer: EqualizerStage,
        exclusiveApp: String?,
        deviceName: String?,
        deviceFormat: AudioFormatInfo?,
        isBluetooth: Bool = false
    ) -> SignalPath {
        guard let deviceName else { return .idle }
        var device = deviceFormat.map { "\(deviceName) · \(Self.describe($0))" } ?? deviceName
        if isBluetooth {
            device += " · Bluetooth, lossy codec"
        }

        if let exclusiveApp {
            // The player owns the device; nothing (including the equalizer) is in between.
            let source = "\(exclusiveApp) (exclusive)"
            return SignalPath(state: isBluetooth ? .bluetooth : .direct, summary: "\(source) → \(deviceName)", detail: "\(source) → \(device)")
        }

        guard !sources.isEmpty else {
            return SignalPath(state: .idle, summary: "Nothing playing → \(deviceName)", detail: "Nothing playing → \(device)")
        }

        let names = sources.map(\.appName).joined(separator: " + ")
        let sourceDetail = sources.map { source in
            source.format.map { "\(source.appName) · \(Self.describe($0))" } ?? source.appName
        }.joined(separator: " + ")
        let stage = equalizer == .processing ? " → \(State.equalizer.label)" : ""
        let summary = "\(names)\(stage) → \(deviceName)"
        let detail = "\(sourceDetail)\(stage) → \(device)"

        let state: State
        if equalizer == .processing {
            state = .equalizer
        } else if sources.count > 1 {
            state = .mixed
        } else if isBluetooth {
            // Matching rates mean nothing here: the codec re-encodes (and often resamples) anyway.
            state = .bluetooth
        } else if let sourceRate = sources[0].format?.sampleRate,
                  let deviceRate = deviceFormat?.sampleRate,
                  abs(sourceRate - deviceRate) >= 1 {
            state = .resampled
        } else {
            state = .direct
        }
        return SignalPath(state: state, summary: summary, detail: detail)
    }

    /// Bundle ID of the app a helper process belongs to: browsers and Electron apps play audio
    /// from helpers like `com.google.Chrome.helper` or `com.microsoft.edgemac.helper.Renderer`.
    /// Safari's media runs in WebKit's GPU process.
    static func owningAppBundleID(of bundleID: String) -> String {
        if bundleID.hasPrefix("com.apple.WebKit.") { return "com.apple.Safari" }
        let parts = bundleID.split(separator: ".")
        if let helper = parts.firstIndex(where: { $0.lowercased() == "helper" }), helper > 0 {
            return parts[..<helper].joined(separator: ".")
        }
        return bundleID
    }

    static func describe(_ format: AudioFormatInfo) -> String {
        "\(AudioFormatInfo.formatRate(format.sampleRate)) / \(format.bitDepth)-bit"
    }
}
