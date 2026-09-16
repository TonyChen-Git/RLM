import AppKit
import XCTest

@testable import LumaChat

final class TaskTerminalSurfaceRenderingTests: XCTestCase {
    @MainActor
    func testAttributedRendererPreservesSafeSGRStylesAndVisibleCursor() throws {
        var emulator = try TaskTerminalEmulator(
            rows: 2,
            columns: 10,
            maximumScrollbackLines: 4
        )
        emulator.feed(Data("\u{1b}[1;4;9;38;2;10;20;30;48;5;196mX".utf8))
        emulator.feed(Data("\u{1b}[7mY\u{1b}[8mZ".utf8))

        let rendered = TaskTerminalSurfaceView.Coordinator.render(
            emulator.snapshot()
        )
        let text = rendered.attributedText.string as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: 0, length: 3)), "XY ")

        let first = rendered.attributedText.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(
            first[.underlineStyle] as? Int,
            NSUnderlineStyle.single.rawValue
        )
        XCTAssertEqual(
            first[.strikethroughStyle] as? Int,
            NSUnderlineStyle.single.rawValue
        )
        assertColor(first[.foregroundColor] as? NSColor, red: 10, green: 20, blue: 30)
        assertColor(first[.backgroundColor] as? NSColor, red: 255, green: 0, blue: 0)
        XCTAssertNil(first[.link])

        let inverse = rendered.attributedText.attributes(at: 1, effectiveRange: nil)
        assertColor(inverse[.foregroundColor] as? NSColor, red: 255, green: 0, blue: 0)
        assertColor(inverse[.backgroundColor] as? NSColor, red: 10, green: 20, blue: 30)

        XCTAssertEqual(rendered.cursorUTF16Offset, 3)
        let cursor = rendered.attributedText.attributes(at: 3, effectiveRange: nil)
        XCTAssertNotNil(cursor[.backgroundColor] as? NSColor)
    }

    @MainActor
    private func assertColor(
        _ color: NSColor?,
        red: Int,
        green: Int,
        blue: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let converted = color?.usingColorSpace(.sRGB) else {
            XCTFail("Missing sRGB color", file: file, line: line)
            return
        }
        XCTAssertEqual(converted.redComponent, CGFloat(red) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.greenComponent, CGFloat(green) / 255, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(converted.blueComponent, CGFloat(blue) / 255, accuracy: 0.001, file: file, line: line)
    }
}
