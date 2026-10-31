import XCTest

final class SignalPathTests: XCTestCase {
    private let cd = AudioFormatInfo(sampleRate: 44_100, bitDepth: 16)
    private let dac441 = AudioFormatInfo(sampleRate: 44_100, bitDepth: 24)
    private let hiRes = AudioFormatInfo(sampleRate: 96_000, bitDepth: 24)

    private func make(
        _ sources: [SignalPath.Source],
        equalizer: SignalPath.EqualizerStage = .off,
        exclusive: String? = nil,
        device: String? = "DX5 II",
        format: AudioFormatInfo? = nil
    ) -> SignalPath {
        SignalPath.make(sources: sources, equalizer: equalizer, exclusiveApp: exclusive, deviceName: device, deviceFormat: format ?? dac441)
    }

    func testMatchedSingleAppIsDirect() {
        let path = make([.init(appName: "Apple Music", format: cd)])
        XCTAssertEqual(path.state, .direct)
        XCTAssertEqual(path.summary, "Apple Music → DX5 II")
        XCTAssertEqual(path.detail, "Apple Music · 44.1 kHz / 16-bit → DX5 II · 44.1 kHz / 24-bit")
    }

    func testRateMismatchIsResampled() {
        XCTAssertEqual(make([.init(appName: "Apple Music", format: hiRes)]).state, .resampled)
    }

    func testUnknownSourceFormatWithOneAppIsDirect() {
        let path = make([.init(appName: "Qobuz", format: nil)])
        XCTAssertEqual(path.state, .direct)
        XCTAssertEqual(path.detail, "Qobuz → DX5 II · 44.1 kHz / 24-bit")
    }

    func testEqualizerWinsAndAppearsInTheChain() {
        let path = make([.init(appName: "Apple Music", format: hiRes)], equalizer: .processing, format: hiRes)
        XCTAssertEqual(path.state, .equalizer)
        XCTAssertEqual(path.summary, "Apple Music → Parametric Equalizer → DX5 II")
        XCTAssertEqual(path.detail, "Apple Music · 96 kHz / 24-bit → Parametric Equalizer → DX5 II · 96 kHz / 24-bit")
    }

    func testSeveralAppsAreMixed() {
        let path = make([.init(appName: "Apple Music", format: cd), .init(appName: "Google Chrome", format: nil)])
        XCTAssertEqual(path.state, .mixed)
        XCTAssertEqual(path.summary, "Apple Music + Google Chrome → DX5 II")
    }

    func testExclusivePlayerIsDirectEvenWithEqualizerOn() {
        let path = make([.init(appName: "Qobuz", format: nil)], equalizer: .processing, exclusive: "Qobuz")
        XCTAssertEqual(path.state, .direct)
        XCTAssertEqual(path.summary, "Qobuz (exclusive) → DX5 II")
    }

    func testNothingPlayingAndNoOutputAreIdle() {
        XCTAssertEqual(make([]).state, .idle)
        XCTAssertEqual(make([]).summary, "Nothing playing → DX5 II")
        XCTAssertEqual(make([.init(appName: "Apple Music", format: cd)], device: nil), .idle)
    }

    func testLabelsAvoidBitPerfect() {
        let labels = [SignalPath.State.idle, .direct, .equalizer, .resampled, .mixed].map(\.label)
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("bit-perfect") })
    }
}
