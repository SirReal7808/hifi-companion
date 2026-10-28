import XCTest

final class LineSplitterTests: XCTestCase {
    func testLineSplitAcrossChunksIsReassembled() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.append(Data("Input format: 2 ch, 1920".utf8)), [])
        XCTAssertEqual(
            splitter.append(Data("00 Hz, alac\nnext".utf8)),
            ["Input format: 2 ch, 192000 Hz, alac"]
        )
        XCTAssertEqual(splitter.append(Data(" line\n".utf8)), ["next line"])
    }

    func testSeveralLinesInOneChunkAndEmptyLinesSkipped() {
        var splitter = LineSplitter()
        XCTAssertEqual(splitter.append(Data("a\n\nb\nc".utf8)), ["a", "b"])
        XCTAssertEqual(splitter.append(Data("\n".utf8)), ["c"])
    }

    func testMultiByteCharacterSplitAcrossChunks() {
        var splitter = LineSplitter()
        let bytes = Array("Mert’s DAC\n".utf8) // ’ is three UTF-8 bytes
        let cut = 6 // inside the ’ sequence
        XCTAssertEqual(splitter.append(Data(bytes[..<cut])), [])
        XCTAssertEqual(splitter.append(Data(bytes[cut...])), ["Mert’s DAC"])
    }

    func testRunawayPartialLineIsDropped() {
        var splitter = LineSplitter()
        let huge = Data(repeating: 0x41, count: LineSplitter.maxPendingBytes + 1)
        XCTAssertEqual(splitter.append(huge), [])
        XCTAssertEqual(splitter.append(Data("ok\n".utf8)), ["ok"])
    }

    func testResetDiscardsPartialLine() {
        var splitter = LineSplitter()
        _ = splitter.append(Data("partial".utf8))
        splitter.reset()
        XCTAssertEqual(splitter.append(Data("fresh\n".utf8)), ["fresh"])
    }
}
