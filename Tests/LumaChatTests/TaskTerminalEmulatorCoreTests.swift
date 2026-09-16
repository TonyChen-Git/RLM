import Foundation
import XCTest
@testable import LumaChat

final class TaskTerminalEmulatorCoreTests: XCTestCase {
    func testIncrementalUTF8WideCombiningAndEmojiClustersAcrossEveryByteBoundary() throws {
        var terminal = try TaskTerminalEmulator(rows: 3, columns: 16)
        let text = "A界e\u{301} 👩\u{200D}💻 🇹🇼"
        for byte in text.utf8 {
            terminal.feed(CollectionOfOne(byte))
        }

        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.screen[0].plainText(), text)
        XCTAssertEqual(snapshot.screen[0].cells[0].text, "A")
        XCTAssertEqual(snapshot.screen[0].cells[1].text, "界")
        XCTAssertEqual(snapshot.screen[0].cells[1].width, 2)
        XCTAssertTrue(snapshot.screen[0].cells[2].isContinuation)
        XCTAssertEqual(snapshot.screen[0].cells[3].text, "e\u{301}")
        XCTAssertEqual(snapshot.screen[0].cells[5].text, "👩\u{200D}💻")
        XCTAssertEqual(snapshot.screen[0].cells[5].width, 2)
        XCTAssertEqual(snapshot.screen[0].cells[8].text, "🇹🇼")
        XCTAssertEqual(snapshot.screen[0].cells[8].width, 2)
    }

    func testIncompleteAndMalformedUTF8UsesReplacementWithoutLosingFollowingControls() throws {
        var terminal = try TaskTerminalEmulator(rows: 2, columns: 12)
        terminal.feed([0xE2, 0x82])
        XCTAssertEqual(terminal.snapshot().screen[0].plainText(), "")
        terminal.feed([0x0D, 0x58])
        XCTAssertEqual(terminal.snapshot().screen[0].plainText(), "X")

        terminal.feed([0xF0, 0x9F])
        terminal.finishInput()
        XCTAssertEqual(terminal.snapshot().screen[0].plainText(), "X�")
    }

    func testC0ControlsTabsCursorMovementAndErase() throws {
        var terminal = try TaskTerminalEmulator(rows: 3, columns: 12)
        terminal.feed(Data("abc\rZ\nX\u{8}Y\tQ".utf8))
        var snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.screen[0].plainText(), "Zbc")
        XCTAssertEqual(snapshot.screen[1].plainText(), " Y      Q")

        terminal.feed(Data("\u{1B}[3;4Hhello".utf8))
        snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.screen[2].plainText(), "   hello")
        XCTAssertEqual(snapshot.cursor, .init(row: 2, column: 8, isVisible: true))

        terminal.feed(Data("\u{1B}[2K".utf8))
        XCTAssertEqual(terminal.snapshot().screen[2].plainText(), "")
    }

    func testCSIInsertDeleteMovementAndGraphicRendition() throws {
        var terminal = try TaskTerminalEmulator(rows: 2, columns: 12)
        terminal.feed(Data("abcdef\u{1B}[1;3H\u{1B}[2P\u{1B}[2@XY".utf8))
        XCTAssertEqual(terminal.snapshot().screen[0].plainText(), "abXYef")

        terminal.feed(Data("\r\u{1B}[1;31;48;2;1;2;3mR\u{1B}[0mN".utf8))
        let cells = terminal.snapshot().screen[0].cells
        XCTAssertEqual(cells[0].text, "R")
        XCTAssertTrue(cells[0].style.attributes.contains(.bold))
        XCTAssertEqual(cells[0].style.foreground, .indexed(1))
        XCTAssertEqual(cells[0].style.background, .rgb(red: 1, green: 2, blue: 3))
        XCTAssertEqual(cells[1].text, "N")
        XCTAssertEqual(cells[1].style, TaskTerminalTextStyle())
    }

    func testPrivateModesAndAlternateScreenRestoreMainScreen() throws {
        var terminal = try TaskTerminalEmulator(rows: 2, columns: 12)
        terminal.feed(Data("main\u{1B}[?1h\u{1B}[?25l\u{1B}[?2004h".utf8))
        var snapshot = terminal.snapshot()
        XCTAssertTrue(snapshot.modes.applicationCursorKeys)
        XCTAssertTrue(snapshot.modes.bracketedPaste)
        XCTAssertFalse(snapshot.cursor.isVisible)

        terminal.feed(Data("\u{1B}[?1049halt".utf8))
        snapshot = terminal.snapshot()
        XCTAssertTrue(snapshot.modes.alternateScreen)
        XCTAssertEqual(snapshot.screen[0].plainText(), "alt")
        XCTAssertTrue(snapshot.scrollback.isEmpty)

        terminal.feed(Data("\u{1B}[?1049l".utf8))
        snapshot = terminal.snapshot()
        XCTAssertFalse(snapshot.modes.alternateScreen)
        XCTAssertEqual(snapshot.screen[0].plainText(), "main")
        XCTAssertTrue(snapshot.modes.applicationCursorKeys)
        XCTAssertTrue(snapshot.modes.bracketedPaste)
    }

    func testOSCClipboardTitleAndLinksAndOtherControlStringsAreIgnored() throws {
        var terminal = try TaskTerminalEmulator(rows: 3, columns: 32)
        let input = """
        BEFORE\u{1B}]52;c;c2VjcmV0\u{7}\u{1B}]0;host-title\u{7}\u{1B}]8;;https://evil.invalid\u{1B}\\label\u{1B}]8;;\u{1B}\\\u{1B}Pprivate-dcs\u{1B}\\AFTER
        """
        terminal.feed(Data(input.utf8))

        let text = terminal.copyText().text
        XCTAssertTrue(text.contains("BEFORElabelAFTER"), text)
        XCTAssertFalse(text.contains("c2VjcmV0"), text)
        XCTAssertFalse(text.contains("host-title"), text)
        XCTAssertFalse(text.contains("evil.invalid"), text)
        XCTAssertFalse(text.contains("private-dcs"), text)
    }

    func testOversizedUnterminatedEscapeStringRecoversToGroundState() throws {
        var terminal = try TaskTerminalEmulator(rows: 2, columns: 32, maximumScrollbackLines: 4)
        var payload = Data("\u{1B}]52;c;".utf8)
        payload.append(Data(repeating: 0x41, count: TaskTerminalEmulator.maximumEscapeSequenceBytes + 64))
        payload.append(Data("TAIL".utf8))
        terminal.feed(payload)

        let copied = terminal.copyText().text
        XCTAssertTrue(copied.hasSuffix("TAIL"), copied)
    }

    func testScrollbackAndCopyRemainBoundedAndSoftWrapDoesNotAddNewline() throws {
        var terminal = try TaskTerminalEmulator(rows: 2, columns: 8, maximumScrollbackLines: 2)
        terminal.feed(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        var snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.scrollback.count, 2)
        XCTAssertEqual(snapshot.scrollback.map { $0.plainText() }, ["one", "two"])
        XCTAssertEqual(snapshot.screen.map { $0.plainText() }, ["three", "four"])

        var wrapped = try TaskTerminalEmulator(rows: 2, columns: 4)
        wrapped.feed(Data("abcdef".utf8))
        snapshot = wrapped.snapshot()
        XCTAssertTrue(snapshot.screen[0].isWrapped)
        XCTAssertEqual(wrapped.copyText().text, "abcdef")

        let bounded = wrapped.copyText(maximumUTF8Bytes: 4)
        XCTAssertEqual(bounded.text, "abcd")
        XCTAssertTrue(bounded.truncated)
    }

    func testSearchAndSelectionCopyUseStableBufferCoordinates() throws {
        var terminal = try TaskTerminalEmulator(rows: 3, columns: 16)
        terminal.feed(Data("Alpha beta\r\nALPHA gamma".utf8))

        let matches = terminal.search("alpha")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.range.start.line), [0, 1])
        XCTAssertEqual(matches.map(\.range.start.column), [0, 0])
        XCTAssertEqual(matches.map(\.range.end.column), [5, 5])

        let wholeWord = terminal.search(
            "beta",
            options: TaskTerminalSearchOptions(
                caseSensitive: true,
                wholeWord: true,
                maximumResults: 10
            )
        )
        XCTAssertEqual(wholeWord.count, 1)

        let copied = terminal.copyText(
            selection: TaskTerminalTextSelection(
                start: .init(line: 0, column: 6),
                end: .init(line: 0, column: 10)
            )
        )
        XCTAssertEqual(copied, TaskTerminalCopyResult(text: "beta", truncated: false))
    }

    func testResizePreservesNewestRowsAndRepairsWideCellBoundary() throws {
        var terminal = try TaskTerminalEmulator(rows: 3, columns: 6, maximumScrollbackLines: 4)
        terminal.feed(Data("first\r\n界xy\r\nlast".utf8))
        try terminal.resize(rows: 2, columns: 2)

        let snapshot = terminal.snapshot()
        XCTAssertEqual(snapshot.rows, 2)
        XCTAssertEqual(snapshot.columns, 2)
        XCTAssertEqual(snapshot.scrollback.last?.plainText(), "fi")
        XCTAssertEqual(snapshot.screen[0].cells.count, 2)
        // A two-column glyph exactly fits the resized row; its second cell is
        // the required zero-width continuation, not a dangling boundary cell.
        XCTAssertTrue(snapshot.screen[0].cells[1].isContinuation)
    }

    func testInvalidConfigurationIsRejected() {
        XCTAssertThrowsError(try TaskTerminalEmulator(rows: 0, columns: 80))
        XCTAssertThrowsError(try TaskTerminalEmulator(rows: 24, columns: 1_001))
        XCTAssertThrowsError(
            try TaskTerminalEmulator(
                rows: 24,
                columns: 80,
                maximumScrollbackLines: TaskTerminalEmulator.maximumScrollbackLines + 1
            )
        )
    }
}
