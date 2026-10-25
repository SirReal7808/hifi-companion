import CoreAudio
import XCTest

// Logic tests compile selected app sources into this target (see project.yml).
// They do not load the menu-bar app host.

final class FormatParserTests: XCTestCase {
    func testParsesALACInputFormat() {
        let line = #"Music ACAppleLosslessDecoder.cpp:680 (0x129c6abe0) Input format: 2 ch, 192000 Hz, alac (0x00000003) from 24-bit source, 4096 frames/packet"#
        let info = FormatParser.parse(line: line)
        XCTAssertEqual(info?.format.sampleRate, 192_000)
        XCTAssertEqual(info?.format.bitDepth, 24)
        XCTAssertEqual(info?.source, .alacInput)
    }

    func testParsesAudioCapabilities() {
        let line = #"Music: [com.apple.Music:ampplay] play> cm>> mediaFormatinfo audioCapabilities: 0x4, asbdFormatID = qlac, sdFormatID = alac, lossless, sdBitDepth = 16 bit, asbdSampleRate = 44.1 kHz"#
        let info = FormatParser.parse(line: line)
        XCTAssertEqual(info?.format.sampleRate, 44_100)
        XCTAssertEqual(info?.format.bitDepth, 16)
        XCTAssertEqual(info?.source, .audioCapabilities)
    }

    func testParsesAudioQueue() {
        let line = #"Music <<<< FAQ >>>> subaq_buildCAAudioQueue: Creating AudioQueue with format:'qlac', framesPerPacket:4096, sampleRate:96000"#
        let info = FormatParser.parse(line: line)
        XCTAssertEqual(info?.format.sampleRate, 96_000)
        XCTAssertEqual(info?.format.bitDepth, 24)
        XCTAssertEqual(info?.source, .audioQueue)
    }

    func testPrefersPaddingSixteenIntoTwentyFour() {
        var sixteen = AudioStreamBasicDescription()
        sixteen.mSampleRate = 44_100
        sixteen.mBitsPerChannel = 16
        var twentyFour = AudioStreamBasicDescription()
        twentyFour.mSampleRate = 44_100
        twentyFour.mBitsPerChannel = 24

        let exact = PhysicalFormatChooser.choose(
            requested: AudioFormatInfo(sampleRate: 44_100, bitDepth: 16),
            available: [sixteen, twentyFour]
        )
        XCTAssertEqual(exact?.mBitsPerChannel, 16)

        let padded = PhysicalFormatChooser.choose(
            requested: AudioFormatInfo(sampleRate: 44_100, bitDepth: 16),
            available: [twentyFour]
        )
        XCTAssertEqual(padded?.mBitsPerChannel, 24)
    }
}
