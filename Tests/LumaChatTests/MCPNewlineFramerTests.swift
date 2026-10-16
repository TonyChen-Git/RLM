import Foundation
import XCTest
@testable import LumaChat

final class MCPNewlineFramerTests: XCTestCase {
    func testLargeFrameAcrossSmallChunksPreservesEveryByte() throws {
        var framer = MCPNewlineFramer()
        let chunk = Data(repeating: 120, count: 1_024)
        for _ in 0..<4_096 {
            XCTAssertTrue(try framer.append(chunk).isEmpty)
        }

        let frames = try framer.append(Data([0x0A]))
        XCTAssertEqual(frames, [Data(repeating: 120, count: 4 * 1_024 * 1_024)])
        XCTAssertTrue(framer.buffer.isEmpty)
    }

    func testConsumedPrefixResetsScanAcrossEmptyAndCRLFLines() throws {
        var framer = MCPNewlineFramer()
        XCTAssertTrue(try framer.append(Data("first".utf8)).isEmpty)
        XCTAssertEqual(
            try framer.append(Data("\n\n\r\nsecond\r\nthi".utf8)),
            [Data("first".utf8), Data("second".utf8)]
        )
        XCTAssertEqual(framer.buffer, Data("thi".utf8))
        XCTAssertTrue(try framer.append(Data()).isEmpty)
        XCTAssertEqual(
            try framer.append(Data("rd\nfourth\n".utf8)),
            [Data("third".utf8), Data("fourth".utf8)]
        )
        XCTAssertTrue(framer.buffer.isEmpty)
    }

    func testLimitAppliesToUnterminatedTailAfterCompleteFrame() throws {
        var framer = MCPNewlineFramer()
        framer.maximumFrameBytes = 4

        assertFrameLimitError { _ = try framer.append(Data("ok\n12345".utf8)) }
        XCTAssertTrue(framer.buffer.isEmpty)
        XCTAssertEqual(try framer.append(Data("next\n".utf8)), [Data("next".utf8)])
    }

    func testLimitFailureClearsScannedPrefixAndTrailingFrames() throws {
        var framer = MCPNewlineFramer()
        framer.maximumFrameBytes = 4
        XCTAssertTrue(try framer.append(Data("1234".utf8)).isEmpty)

        assertFrameLimitError { _ = try framer.append(Data("5\nlater\n".utf8)) }
        XCTAssertTrue(framer.buffer.isEmpty)
        XCTAssertEqual(try framer.append(Data("ok\n".utf8)), [Data("ok".utf8)])
    }

    func testLimitAcceptsExactBoundaryAndCountsOnlyIndividualFrames() throws {
        var framer = MCPNewlineFramer()
        framer.maximumFrameBytes = 4
        XCTAssertTrue(try framer.append(Data("1234".utf8)).isEmpty)
        XCTAssertEqual(
            try framer.append(Data("\r\n5678\n".utf8)),
            [Data("1234".utf8), Data("5678".utf8)]
        )
        XCTAssertTrue(framer.buffer.isEmpty)

        XCTAssertTrue(try framer.append(Data("1234".utf8)).isEmpty)
        assertFrameLimitError { _ = try framer.append(Data("5".utf8)) }
        XCTAssertTrue(framer.buffer.isEmpty)
        XCTAssertEqual(try framer.append(Data("done\n".utf8)), [Data("done".utf8)])
    }

    private func assertFrameLimitError(
        _ operation: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case MCPError.invalidResponse = error else {
                return XCTFail("Expected frame limit rejection, received \(error)", file: file, line: line)
            }
        }
    }
}
