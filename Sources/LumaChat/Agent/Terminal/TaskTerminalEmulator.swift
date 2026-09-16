import Foundation

enum TaskTerminalEmulatorError: LocalizedError, Equatable, Sendable {
    case invalidDimensions(rows: Int, columns: Int)
    case invalidScrollbackLimit(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDimensions(let rows, let columns):
            "Terminal dimensions must be between 1 and 1,000 cells per axis (received \(rows)x\(columns))."
        case .invalidScrollbackLimit(let limit):
            "Terminal scrollback limit must be between 0 and 20,000 lines (received \(limit))."
        }
    }
}

enum TaskTerminalColor: Codable, Equatable, Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(red: UInt8, green: UInt8, blue: UInt8)
}

struct TaskTerminalTextAttributes: OptionSet, Codable, Equatable, Hashable, Sendable {
    let rawValue: UInt16

    static let bold = Self(rawValue: 1 << 0)
    static let dim = Self(rawValue: 1 << 1)
    static let italic = Self(rawValue: 1 << 2)
    static let underline = Self(rawValue: 1 << 3)
    static let blink = Self(rawValue: 1 << 4)
    static let inverse = Self(rawValue: 1 << 5)
    static let hidden = Self(rawValue: 1 << 6)
    static let strikethrough = Self(rawValue: 1 << 7)
}

struct TaskTerminalTextStyle: Codable, Equatable, Hashable, Sendable {
    var foreground: TaskTerminalColor = .default
    var background: TaskTerminalColor = .default
    var attributes: TaskTerminalTextAttributes = []
}

/// One fixed-width terminal cell. A double-width glyph is represented by a
/// width-two leading cell followed by a width-zero continuation cell. Host UI
/// code must never interpret `text` as markup, a URL, or an escape sequence.
struct TaskTerminalCell: Codable, Equatable, Hashable, Sendable {
    var text: String
    var width: UInt8
    var style: TaskTerminalTextStyle

    var isContinuation: Bool { width == 0 }
    var isBlank: Bool { !isContinuation && text.isEmpty }
}

struct TaskTerminalStyledRun: Codable, Equatable, Sendable {
    var text: String
    var startColumn: Int
    var columnCount: Int
    var style: TaskTerminalTextStyle
}

struct TaskTerminalSnapshotLine: Codable, Equatable, Sendable {
    var cells: [TaskTerminalCell]
    /// `true` means the following physical row is a continuation created by
    /// terminal autowrap, so copying should not insert a newline between them.
    var isWrapped: Bool

    func plainText(trimTrailingWhitespace: Bool = true) -> String {
        var value = ""
        value.reserveCapacity(cells.count)
        for cell in cells where !cell.isContinuation {
            value += cell.text.isEmpty ? " " : cell.text
        }
        guard trimTrailingWhitespace else { return value }
        while value.last == " " { value.removeLast() }
        return value
    }

    func styledRuns(trimTrailingWhitespace: Bool = true) -> [TaskTerminalStyledRun] {
        var runs: [TaskTerminalStyledRun] = []
        var currentText = ""
        var currentStyle: TaskTerminalTextStyle?
        var currentColumn = 0
        var currentWidth = 0

        func flush() {
            guard let currentStyle, !currentText.isEmpty else { return }
            runs.append(
                TaskTerminalStyledRun(
                    text: currentText,
                    startColumn: currentColumn,
                    columnCount: currentWidth,
                    style: currentStyle
                )
            )
        }

        for (column, cell) in cells.enumerated() where !cell.isContinuation {
            let text = cell.text.isEmpty ? " " : cell.text
            if currentStyle == cell.style {
                currentText += text
                currentWidth += Int(cell.width)
            } else {
                flush()
                currentText = text
                currentStyle = cell.style
                currentColumn = column
                currentWidth = Int(cell.width)
            }
        }
        flush()

        guard trimTrailingWhitespace else { return runs }
        while let last = runs.last {
            let trimmed = last.text.drop(whileFromEnd: { $0 == " " })
            if trimmed.isEmpty {
                runs.removeLast()
                continue
            }
            if trimmed.count != last.text.count {
                var updated = last
                let removed = last.text.count - trimmed.count
                updated.text = String(trimmed)
                updated.columnCount = max(0, updated.columnCount - removed)
                runs[runs.count - 1] = updated
            }
            break
        }
        return runs
    }
}

struct TaskTerminalCursor: Codable, Equatable, Sendable {
    var row: Int
    var column: Int
    var isVisible: Bool
}

struct TaskTerminalModes: Codable, Equatable, Sendable {
    var alternateScreen: Bool
    var applicationCursorKeys: Bool
    var applicationKeypad: Bool
    var bracketedPaste: Bool
    var origin: Bool
    var autowrap: Bool
    var insert: Bool
    var newline: Bool
}

struct TaskTerminalBufferPosition: Codable, Comparable, Equatable, Sendable {
    /// Zero-based index into `snapshot.allLines`, including scrollback.
    var line: Int
    var column: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line ? lhs.column < rhs.column : lhs.line < rhs.line
    }
}

struct TaskTerminalTextSelection: Codable, Equatable, Sendable {
    var start: TaskTerminalBufferPosition
    var end: TaskTerminalBufferPosition
}

struct TaskTerminalSearchOptions: Codable, Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var maximumResults = 1_000
}

struct TaskTerminalSearchMatch: Codable, Equatable, Sendable {
    var range: TaskTerminalTextSelection
    var text: String
}

struct TaskTerminalCopyResult: Codable, Equatable, Sendable {
    var text: String
    var truncated: Bool
}

struct TaskTerminalSnapshot: Codable, Equatable, Sendable {
    var rows: Int
    var columns: Int
    var scrollback: [TaskTerminalSnapshotLine]
    var screen: [TaskTerminalSnapshotLine]
    var cursor: TaskTerminalCursor
    var modes: TaskTerminalModes

    var allLines: [TaskTerminalSnapshotLine] { scrollback + screen }

    func search(
        _ query: String,
        options: TaskTerminalSearchOptions = .init()
    ) -> [TaskTerminalSearchMatch] {
        guard !query.isEmpty, options.maximumResults > 0 else { return [] }
        let lines = allLines
        let needleLength = (query as NSString).length
        guard needleLength > 0 else { return [] }
        var matches: [TaskTerminalSearchMatch] = []
        let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]

        for (lineIndex, line) in lines.enumerated() {
            let text = line.plainText()
            let source = text as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0, matches.count < options.maximumResults {
                let found = source.range(of: query, options: compareOptions, range: searchRange)
                guard found.location != NSNotFound else { break }
                let end = found.location + found.length
                if !options.wholeWord || Self.isWholeWord(source, range: found) {
                    matches.append(
                        TaskTerminalSearchMatch(
                            range: TaskTerminalTextSelection(
                                start: .init(
                                    line: lineIndex,
                                    column: line.column(atUTF16Offset: found.location)
                                ),
                                end: .init(
                                    line: lineIndex,
                                    column: line.column(atUTF16Offset: end)
                                )
                            ),
                            text: source.substring(with: found)
                        )
                    )
                }
                let next = max(end, found.location + 1)
                guard next <= source.length else { break }
                searchRange = NSRange(location: next, length: source.length - next)
            }
            if matches.count >= options.maximumResults { break }
        }
        return matches
    }

    func copyText(
        selection: TaskTerminalTextSelection? = nil,
        maximumUTF8Bytes: Int = 1 * 1_024 * 1_024
    ) -> TaskTerminalCopyResult {
        let lines = allLines
        guard !lines.isEmpty, maximumUTF8Bytes > 0 else {
            return TaskTerminalCopyResult(text: "", truncated: !lines.isEmpty)
        }

        let rawStart = selection?.start ?? .init(line: 0, column: 0)
        let rawEnd = selection?.end ?? .init(
            line: lines.count - 1,
            column: lines[lines.count - 1].cells.count
        )
        let start = min(rawStart, rawEnd)
        let end = max(rawStart, rawEnd)
        guard start.line >= 0, start.line < lines.count, end.line >= 0 else {
            return TaskTerminalCopyResult(text: "", truncated: false)
        }
        let finalLine = min(end.line, lines.count - 1)
        guard start.line <= finalLine else {
            return TaskTerminalCopyResult(text: "", truncated: false)
        }

        var result = ""
        var usedBytes = 0
        var truncated = false

        func appendBounded(_ value: String) -> Bool {
            for character in value {
                let piece = String(character)
                let count = piece.utf8.count
                guard usedBytes + count <= maximumUTF8Bytes else { return false }
                result += piece
                usedBytes += count
            }
            return true
        }

        for lineIndex in start.line...finalLine {
            let line = lines[lineIndex]
            let lower = lineIndex == start.line ? max(0, start.column) : 0
            let upper = lineIndex == end.line ? max(0, end.column) : line.cells.count
            let piece = line.text(inColumns: lower..<min(max(lower, upper), line.cells.count))
                .trimmingTrailingSpaces()
            if !appendBounded(piece) {
                truncated = true
                break
            }
            if lineIndex < finalLine, !line.isWrapped, !appendBounded("\n") {
                truncated = true
                break
            }
        }
        return TaskTerminalCopyResult(text: result, truncated: truncated)
    }

    private static func isWholeWord(_ value: NSString, range: NSRange) -> Bool {
        let word = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        if range.location > 0 {
            let previous = value.substring(with: NSRange(location: range.location - 1, length: 1))
            if previous.unicodeScalars.contains(where: word.contains) { return false }
        }
        let end = range.location + range.length
        if end < value.length {
            let next = value.substring(with: NSRange(location: end, length: 1))
            if next.unicodeScalars.contains(where: word.contains) { return false }
        }
        return true
    }
}

/// A bounded, side-effect-free VT/ANSI display model. It deliberately has no
/// callbacks into AppKit, clipboard, networking, URL handling, or process I/O.
/// Feed it the combined PTY byte stream and render immutable snapshots.
struct TaskTerminalEmulator: Sendable {
    static let defaultScrollbackLines = 10_000
    static let maximumScrollbackLines = 20_000
    static let maximumDimension = 1_000
    static let maximumEscapeSequenceBytes = 4_096
    private static let maximumScrollbackCells = 4_000_000

    private var mainScreen: ScreenState
    private var alternateScreen: ScreenState
    private var history: LineRing
    private var configuredScrollbackLines: Int
    private var usingAlternateScreen = false
    private var applicationCursorKeys = false
    private var applicationKeypad = false
    private var bracketedPaste = false
    private var parserState = ParserState.ground
    private var sequenceBytes = 0
    private var csiBytes: [UInt8] = []
    private var utf8Decoder = IncrementalUTF8Decoder()
    private var joinNextScalar = false

    init(
        rows: Int,
        columns: Int,
        maximumScrollbackLines: Int = Self.defaultScrollbackLines
    ) throws {
        guard (1...Self.maximumDimension).contains(rows),
              (1...Self.maximumDimension).contains(columns) else {
            throw TaskTerminalEmulatorError.invalidDimensions(rows: rows, columns: columns)
        }
        guard (0...Self.maximumScrollbackLines).contains(maximumScrollbackLines) else {
            throw TaskTerminalEmulatorError.invalidScrollbackLimit(maximumScrollbackLines)
        }
        let style = TaskTerminalTextStyle()
        mainScreen = ScreenState(rows: rows, columns: columns, style: style)
        alternateScreen = ScreenState(rows: rows, columns: columns, style: style)
        configuredScrollbackLines = maximumScrollbackLines
        history = LineRing(capacity: Self.historyCapacity(maximumScrollbackLines, columns: columns))
    }

    mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes { consume(byte) }
    }

    /// Flushes a final incomplete UTF-8 scalar as U+FFFD and safely abandons
    /// any unterminated escape string. Call this only when the PTY reaches EOF.
    mutating func finishInput() {
        if utf8Decoder.hasPendingScalar {
            utf8Decoder.reset()
            writeUnicode("\u{FFFD}")
        }
        parserState = .ground
        sequenceBytes = 0
        csiBytes.removeAll(keepingCapacity: true)
        joinNextScalar = false
    }

    mutating func resize(rows: Int, columns: Int) throws {
        guard (1...Self.maximumDimension).contains(rows),
              (1...Self.maximumDimension).contains(columns) else {
            throw TaskTerminalEmulatorError.invalidDimensions(rows: rows, columns: columns)
        }
        var removed: [TerminalLine] = []
        mainScreen.resize(rows: rows, columns: columns, removedFromTop: &removed)
        for line in removed { history.append(line) }
        var discarded: [TerminalLine] = []
        alternateScreen.resize(rows: rows, columns: columns, removedFromTop: &discarded)
        history.setCapacity(Self.historyCapacity(configuredScrollbackLines, columns: columns))
    }

    mutating func clearScrollback() {
        history.removeAll()
    }

    mutating func reset() {
        let rows = mainScreen.rows
        let columns = mainScreen.columns
        mainScreen = ScreenState(rows: rows, columns: columns, style: .init())
        alternateScreen = ScreenState(rows: rows, columns: columns, style: .init())
        history.removeAll()
        usingAlternateScreen = false
        applicationCursorKeys = false
        applicationKeypad = false
        bracketedPaste = false
        parserState = .ground
        sequenceBytes = 0
        csiBytes.removeAll(keepingCapacity: true)
        utf8Decoder.reset()
        joinNextScalar = false
    }

    func snapshot(includeScrollback: Bool = true) -> TaskTerminalSnapshot {
        let screen = usingAlternateScreen ? alternateScreen : mainScreen
        return TaskTerminalSnapshot(
            rows: screen.rows,
            columns: screen.columns,
            scrollback: includeScrollback && !usingAlternateScreen
                ? history.elements.map(\.snapshot)
                : [],
            screen: screen.lines.map(\.snapshot),
            cursor: TaskTerminalCursor(
                row: screen.cursorRow,
                column: screen.cursorColumn,
                isVisible: screen.cursorVisible
            ),
            modes: TaskTerminalModes(
                alternateScreen: usingAlternateScreen,
                applicationCursorKeys: applicationCursorKeys,
                applicationKeypad: applicationKeypad,
                bracketedPaste: bracketedPaste,
                origin: screen.originMode,
                autowrap: screen.autowrapMode,
                insert: screen.insertMode,
                newline: screen.newlineMode
            )
        )
    }

    func search(
        _ query: String,
        options: TaskTerminalSearchOptions = .init()
    ) -> [TaskTerminalSearchMatch] {
        snapshot().search(query, options: options)
    }

    func copyText(
        selection: TaskTerminalTextSelection? = nil,
        maximumUTF8Bytes: Int = 1 * 1_024 * 1_024
    ) -> TaskTerminalCopyResult {
        snapshot().copyText(selection: selection, maximumUTF8Bytes: maximumUTF8Bytes)
    }

    private static func historyCapacity(_ requested: Int, columns: Int) -> Int {
        min(requested, maximumScrollbackCells / max(1, columns))
    }

    private mutating func consume(_ byte: UInt8) {
        switch parserState {
        case .ground:
            consumeGround(byte)
        case .escape:
            consumeEscape(byte)
        case .charset:
            finishSequence()
        case .csi:
            consumeCSI(byte)
        case .osc:
            consumeIgnoredString(byte, escapeState: .oscEscape)
        case .oscEscape:
            if byte == 0x5C { finishSequence() } else { resumeIgnoredString(.osc, byte: byte) }
        case .ignoredString:
            consumeIgnoredString(byte, escapeState: .ignoredStringEscape)
        case .ignoredStringEscape:
            if byte == 0x5C { finishSequence() } else { resumeIgnoredString(.ignoredString, byte: byte) }
        }
    }

    private mutating func consumeGround(_ byte: UInt8) {
        if utf8Decoder.hasPendingScalar {
            switch utf8Decoder.consume(byte) {
            case .needMore:
                return
            case .scalar(let scalar):
                writeUnicode(scalar)
                return
            case .invalid(let reprocess):
                writeUnicode("\u{FFFD}")
                if reprocess { consumeGround(byte) }
                return
            }
        }

        switch byte {
        case 0x00, 0x05, 0x06, 0x0E, 0x0F, 0x7F:
            return
        case 0x07:
            // Bell is intentionally display-only; no sound or host callback.
            return
        case 0x08:
            mutateActiveScreen { $0.backspace() }
            joinNextScalar = false
        case 0x09:
            mutateActiveScreen { $0.horizontalTab() }
            joinNextScalar = false
        case 0x0A, 0x0B, 0x0C:
            lineFeed(softWrapped: false)
            joinNextScalar = false
        case 0x0D:
            mutateActiveScreen { $0.carriageReturn() }
            joinNextScalar = false
        case 0x18, 0x1A:
            return
        case 0x1B:
            parserState = .escape
            sequenceBytes = 1
            joinNextScalar = false
        case 0x20...0x7E:
            writeUnicode(UnicodeScalar(byte))
        case 0x90, 0x98, 0x9E, 0x9F:
            parserState = .ignoredString
            sequenceBytes = 1
        case 0x9B:
            parserState = .csi
            sequenceBytes = 1
            csiBytes.removeAll(keepingCapacity: true)
        case 0x9C:
            return
        case 0x9D:
            parserState = .osc
            sequenceBytes = 1
        default:
            switch utf8Decoder.consume(byte) {
            case .needMore:
                break
            case .scalar(let scalar):
                writeUnicode(scalar)
            case .invalid:
                writeUnicode("\u{FFFD}")
            }
        }
    }

    private mutating func consumeEscape(_ byte: UInt8) {
        sequenceBytes += 1
        guard sequenceBytes <= Self.maximumEscapeSequenceBytes else {
            finishSequence()
            return
        }
        switch byte {
        case 0x18, 0x1A:
            finishSequence()
        case 0x1B:
            sequenceBytes = 1
        case 0x5B:
            parserState = .csi
            csiBytes.removeAll(keepingCapacity: true)
        case 0x5D:
            parserState = .osc
        case 0x50, 0x58, 0x5E, 0x5F:
            parserState = .ignoredString
        case 0x28, 0x29, 0x2A, 0x2B:
            parserState = .charset
        case 0x37:
            mutateActiveScreen { $0.saveCursor() }
            finishSequence()
        case 0x38:
            mutateActiveScreen { $0.restoreCursor() }
            finishSequence()
        case 0x44:
            lineFeed(softWrapped: false)
            finishSequence()
        case 0x45:
            mutateActiveScreen { $0.carriageReturn() }
            lineFeed(softWrapped: false)
            finishSequence()
        case 0x48:
            mutateActiveScreen { $0.setTabStop() }
            finishSequence()
        case 0x4D:
            reverseIndex()
            finishSequence()
        case 0x63:
            reset()
        case 0x3D:
            applicationKeypad = true
            finishSequence()
        case 0x3E:
            applicationKeypad = false
            finishSequence()
        default:
            // Unknown two-byte escape sequences are consumed, never rendered.
            finishSequence()
        }
    }

    private mutating func consumeCSI(_ byte: UInt8) {
        sequenceBytes += 1
        guard sequenceBytes <= Self.maximumEscapeSequenceBytes,
              csiBytes.count < 256 else {
            finishSequence()
            return
        }
        switch byte {
        case 0x18, 0x1A:
            finishSequence()
        case 0x1B:
            parserState = .escape
            sequenceBytes = 1
            csiBytes.removeAll(keepingCapacity: true)
        case 0x40...0x7E:
            executeCSI(final: byte, body: csiBytes)
            finishSequence()
        case 0x20...0x3F:
            csiBytes.append(byte)
        default:
            // Invalid CSI bytes terminate the sequence fail-safe.
            finishSequence()
        }
    }

    private mutating func consumeIgnoredString(_ byte: UInt8, escapeState: ParserState) {
        sequenceBytes += 1
        guard sequenceBytes <= Self.maximumEscapeSequenceBytes else {
            finishSequence()
            return
        }
        switch byte {
        case 0x07 where parserState == .osc:
            finishSequence()
        case 0x18, 0x1A, 0x9C:
            finishSequence()
        case 0x1B:
            parserState = escapeState
        default:
            return
        }
    }

    private mutating func resumeIgnoredString(_ state: ParserState, byte: UInt8) {
        parserState = state
        sequenceBytes += 1
        guard sequenceBytes <= Self.maximumEscapeSequenceBytes else {
            finishSequence()
            return
        }
        if byte == 0x1B {
            parserState = state == .osc ? .oscEscape : .ignoredStringEscape
        }
    }

    private mutating func finishSequence() {
        parserState = .ground
        sequenceBytes = 0
        csiBytes.removeAll(keepingCapacity: true)
    }

    private mutating func executeCSI(final: UInt8, body: [UInt8]) {
        let parsed = CSIParameters(body)
        switch final {
        case 0x40: // ICH
            mutateActiveScreen { $0.insertCharacters(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x41: // CUU
            mutateActiveScreen { $0.moveCursor(rows: -parsed.value(at: 0, default: 1, zeroIsDefault: true), columns: 0) }
        case 0x42, 0x65: // CUD / VPR
            mutateActiveScreen { $0.moveCursor(rows: parsed.value(at: 0, default: 1, zeroIsDefault: true), columns: 0) }
        case 0x43, 0x61: // CUF / HPR
            mutateActiveScreen { $0.moveCursor(rows: 0, columns: parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x44: // CUB
            mutateActiveScreen { $0.moveCursor(rows: 0, columns: -parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x45: // CNL
            mutateActiveScreen {
                $0.moveCursor(rows: parsed.value(at: 0, default: 1, zeroIsDefault: true), columns: 0)
                $0.carriageReturn()
            }
        case 0x46: // CPL
            mutateActiveScreen {
                $0.moveCursor(rows: -parsed.value(at: 0, default: 1, zeroIsDefault: true), columns: 0)
                $0.carriageReturn()
            }
        case 0x47, 0x60: // CHA / HPA
            mutateActiveScreen { $0.setCursorColumn(parsed.value(at: 0, default: 1, zeroIsDefault: true) - 1) }
        case 0x48, 0x66: // CUP / HVP
            mutateActiveScreen {
                $0.setCursor(
                    row: parsed.value(at: 0, default: 1, zeroIsDefault: true) - 1,
                    column: parsed.value(at: 1, default: 1, zeroIsDefault: true) - 1
                )
            }
        case 0x49: // CHT
            mutateActiveScreen { $0.forwardTabs(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x4A: // ED
            let mode = parsed.value(at: 0, default: 0)
            if mode == 3 { history.removeAll() }
            mutateActiveScreen { $0.eraseDisplay(mode: mode) }
        case 0x4B: // EL
            mutateActiveScreen { $0.eraseLine(mode: parsed.value(at: 0, default: 0)) }
        case 0x4C: // IL
            mutateActiveScreen { $0.insertLines(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x4D: // DL
            mutateActiveScreen { $0.deleteLines(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x50: // DCH
            mutateActiveScreen { $0.deleteCharacters(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x53: // SU
            scrollUp(parsed.value(at: 0, default: 1, zeroIsDefault: true))
        case 0x54: // SD
            mutateActiveScreen { $0.scrollDown(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x58: // ECH
            mutateActiveScreen { $0.eraseCharacters(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x5A: // CBT
            mutateActiveScreen { $0.backwardTabs(parsed.value(at: 0, default: 1, zeroIsDefault: true)) }
        case 0x64: // VPA
            mutateActiveScreen { $0.setCursorRow(parsed.value(at: 0, default: 1, zeroIsDefault: true) - 1) }
        case 0x67: // TBC
            mutateActiveScreen { $0.clearTabStops(mode: parsed.value(at: 0, default: 0)) }
        case 0x68: // SM / DECSET
            setModes(parsed, enabled: true)
        case 0x6C: // RM / DECRST
            setModes(parsed, enabled: false)
        case 0x6D: // SGR
            setGraphicRendition(parsed.sgrValues)
        case 0x72: // DECSTBM
            mutateActiveScreen {
                $0.setScrollRegion(
                    top: parsed.value(at: 0, default: 1, zeroIsDefault: true) - 1,
                    bottom: parsed.value(at: 1, default: $0.rows, zeroIsDefault: true) - 1
                )
            }
        case 0x73: // SCP
            mutateActiveScreen { $0.saveCursor() }
        case 0x75: // RCP
            mutateActiveScreen { $0.restoreCursor() }
        default:
            // Queries and unsupported operations produce no reply and no host
            // side effect. PTY input is owned by the caller, not this model.
            break
        }
    }

    private mutating func setModes(_ parameters: CSIParameters, enabled: Bool) {
        for value in parameters.values(defaultIfEmpty: 0) {
            if parameters.privateMarker == "?" {
                switch value {
                case 1:
                    applicationCursorKeys = enabled
                case 6:
                    mutateActiveScreen { screen in
                        screen.originMode = enabled
                        screen.setCursor(row: 0, column: 0)
                    }
                case 7:
                    mutateActiveScreen { $0.autowrapMode = enabled }
                case 25:
                    mutateActiveScreen { $0.cursorVisible = enabled }
                case 47, 1047, 1049:
                    setAlternateScreen(enabled)
                case 2004:
                    bracketedPaste = enabled
                default:
                    break
                }
            } else {
                switch value {
                case 4:
                    mutateActiveScreen { $0.insertMode = enabled }
                case 20:
                    mutateActiveScreen { $0.newlineMode = enabled }
                default:
                    break
                }
            }
        }
    }

    private mutating func setAlternateScreen(_ enabled: Bool) {
        guard enabled != usingAlternateScreen else { return }
        if enabled {
            mainScreen.saveCursor()
            alternateScreen = ScreenState(
                rows: mainScreen.rows,
                columns: mainScreen.columns,
                style: .init()
            )
            usingAlternateScreen = true
        } else {
            usingAlternateScreen = false
            mainScreen.restoreCursor()
        }
        joinNextScalar = false
    }

    private mutating func setGraphicRendition(_ rawValues: [Int?]) {
        let values = rawValues.isEmpty ? [Optional(0)] : rawValues
        mutateActiveScreen { screen in
            var index = 0
            while index < values.count {
                let value = values[index] ?? 0
                switch value {
                case 0:
                    screen.style = .init()
                case 1: screen.style.attributes.insert(.bold)
                case 2: screen.style.attributes.insert(.dim)
                case 3: screen.style.attributes.insert(.italic)
                case 4, 21: screen.style.attributes.insert(.underline)
                case 5, 6: screen.style.attributes.insert(.blink)
                case 7: screen.style.attributes.insert(.inverse)
                case 8: screen.style.attributes.insert(.hidden)
                case 9: screen.style.attributes.insert(.strikethrough)
                case 22:
                    screen.style.attributes.subtract([.bold, .dim])
                case 23: screen.style.attributes.remove(.italic)
                case 24: screen.style.attributes.remove(.underline)
                case 25: screen.style.attributes.remove(.blink)
                case 27: screen.style.attributes.remove(.inverse)
                case 28: screen.style.attributes.remove(.hidden)
                case 29: screen.style.attributes.remove(.strikethrough)
                case 30...37:
                    screen.style.foreground = .indexed(UInt8(value - 30))
                case 39:
                    screen.style.foreground = .default
                case 40...47:
                    screen.style.background = .indexed(UInt8(value - 40))
                case 49:
                    screen.style.background = .default
                case 90...97:
                    screen.style.foreground = .indexed(UInt8(value - 90 + 8))
                case 100...107:
                    screen.style.background = .indexed(UInt8(value - 100 + 8))
                case 38, 48:
                    let isForeground = value == 38
                    if index + 2 < values.count, values[index + 1] == 5,
                       let palette = values[index + 2], (0...255).contains(palette) {
                        if isForeground {
                            screen.style.foreground = .indexed(UInt8(palette))
                        } else {
                            screen.style.background = .indexed(UInt8(palette))
                        }
                        index += 2
                    } else if index + 4 < values.count, values[index + 1] == 2,
                              let red = values[index + 2], let green = values[index + 3],
                              let blue = values[index + 4],
                              (0...255).contains(red), (0...255).contains(green),
                              (0...255).contains(blue) {
                        let color = TaskTerminalColor.rgb(
                            red: UInt8(red), green: UInt8(green), blue: UInt8(blue)
                        )
                        if isForeground {
                            screen.style.foreground = color
                        } else {
                            screen.style.background = color
                        }
                        index += 4
                    }
                default:
                    break
                }
                index += 1
            }
        }
    }

    private mutating func writeUnicode(_ scalar: UnicodeScalar) {
        if scalar.value == 0x200D {
            appendToPreviousCell(scalar, fallbackToDottedCircle: false)
            joinNextScalar = true
            return
        }
        if joinNextScalar {
            appendToPreviousCell(scalar, fallbackToDottedCircle: true)
            joinNextScalar = false
            return
        }
        if Self.isZeroWidth(scalar) {
            appendToPreviousCell(scalar, fallbackToDottedCircle: true)
            return
        }
        if Self.isRegionalIndicator(scalar), appendRegionalIndicatorIfPossible(scalar) {
            return
        }

        var removed: TerminalLine?
        let width = Self.displayWidth(of: scalar)
        mutateActiveScreen { screen in
            removed = screen.write(String(scalar), width: width)
        }
        appendHistoryIfNeeded(removed)
    }

    private mutating func appendToPreviousCell(
        _ scalar: UnicodeScalar,
        fallbackToDottedCircle: Bool
    ) {
        var didAppend = false
        mutateActiveScreen { screen in
            didAppend = screen.appendToPreviousCell(String(scalar))
        }
        if !didAppend, fallbackToDottedCircle {
            var removed: TerminalLine?
            mutateActiveScreen { screen in
                removed = screen.write("\u{25CC}\(scalar)", width: 1)
            }
            appendHistoryIfNeeded(removed)
        }
    }

    private mutating func appendRegionalIndicatorIfPossible(_ scalar: UnicodeScalar) -> Bool {
        var appended = false
        mutateActiveScreen { screen in
            guard let previous = screen.previousLeadingCell(),
                  previous.text.unicodeScalars.count == 1,
                  let first = previous.text.unicodeScalars.first,
                  Self.isRegionalIndicator(first) else { return }
            appended = screen.appendToPreviousCell(String(scalar))
        }
        return appended
    }

    private mutating func lineFeed(softWrapped: Bool) {
        var removed: TerminalLine?
        mutateActiveScreen { screen in
            removed = screen.lineFeed(softWrapped: softWrapped)
        }
        appendHistoryIfNeeded(removed)
    }

    private mutating func reverseIndex() {
        mutateActiveScreen { $0.reverseIndex() }
    }

    private mutating func scrollUp(_ count: Int) {
        var removed: [TerminalLine] = []
        mutateActiveScreen { screen in
            removed = screen.scrollUp(count)
        }
        guard !usingAlternateScreen else { return }
        for line in removed { history.append(line) }
    }

    private mutating func appendHistoryIfNeeded(_ line: TerminalLine?) {
        guard !usingAlternateScreen, let line else { return }
        history.append(line)
    }

    private mutating func mutateActiveScreen(_ body: (inout ScreenState) -> Void) {
        if usingAlternateScreen {
            body(&alternateScreen)
        } else {
            body(&mainScreen)
        }
    }

    private static func isZeroWidth(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        if value == 0x200B || value == 0x200C || value == 0x200D || value == 0x2060
            || value == 0xFEFF || (0xFE00...0xFE0F).contains(value)
            || (0xE0100...0xE01EF).contains(value)
            || (0x1F3FB...0x1F3FF).contains(value) {
            return true
        }
        return CharacterSet.nonBaseCharacters.contains(scalar)
    }

    private static func displayWidth(of scalar: UnicodeScalar) -> Int {
        wideScalarRanges.contains(where: { $0.contains(scalar.value) }) ? 2 : 1
    }

    private static let wideScalarRanges: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x231A...0x231B, 0x2329...0x232A,
        0x23E9...0x23EC, 0x23F0...0x23F0, 0x23F3...0x23F3,
        0x25FD...0x25FE, 0x2614...0x2615, 0x2648...0x2653,
        0x267F...0x267F, 0x2693...0x2693, 0x26A1...0x26A1,
        0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5,
        0x26CE...0x26CE, 0x26D4...0x26D4, 0x26EA...0x26EA,
        0x26F2...0x26F3, 0x26F5...0x26F5, 0x26FA...0x26FA,
        0x26FD...0x26FD, 0x2705...0x2705, 0x270A...0x270B,
        0x2728...0x2728, 0x274C...0x274C, 0x274E...0x274E,
        0x2753...0x2755, 0x2757...0x2757, 0x2795...0x2797,
        0x27B0...0x27B0, 0x27BF...0x27BF, 0x2B1B...0x2B1C,
        0x2B50...0x2B50, 0x2B55...0x2B55, 0x2E80...0x303E,
        0x3040...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
        0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
        0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...0x3FFFD
    ]

    private static func isRegionalIndicator(_ scalar: UnicodeScalar) -> Bool {
        (0x1F1E6...0x1F1FF).contains(scalar.value)
    }
}

private enum ParserState: Equatable, Sendable {
    case ground
    case escape
    case charset
    case csi
    case osc
    case oscEscape
    case ignoredString
    case ignoredStringEscape
}

private struct CSIParameters: Sendable {
    let privateMarker: Character?
    let rawParameterText: String

    init(_ bytes: [UInt8]) {
        var parameterBytes: [UInt8] = []
        var marker: Character?
        for byte in bytes {
            if parameterBytes.isEmpty, (0x3C...0x3F).contains(byte) {
                marker = Character(UnicodeScalar(byte))
            } else if (0x30...0x3F).contains(byte) {
                parameterBytes.append(byte)
            }
            // Intermediates are intentionally ignored. The final byte still
            // terminates the bounded sequence, which is the fail-safe path.
        }
        privateMarker = marker
        rawParameterText = String(decoding: parameterBytes, as: UTF8.self)
    }

    var sgrValues: [Int?] {
        Self.parse(rawParameterText.replacingOccurrences(of: ":", with: ";"))
    }

    func value(at index: Int, default defaultValue: Int, zeroIsDefault: Bool = false) -> Int {
        let parsed = Self.parse(rawParameterText)
        guard index < parsed.count, let value = parsed[index] else { return defaultValue }
        return zeroIsDefault && value == 0 ? defaultValue : min(value, 1_000_000)
    }

    func values(defaultIfEmpty defaultValue: Int) -> [Int] {
        let parsed = Self.parse(rawParameterText)
        return parsed.isEmpty ? [defaultValue] : parsed.map { min($0 ?? defaultValue, 1_000_000) }
    }

    private static func parse(_ value: String) -> [Int?] {
        guard !value.isEmpty else { return [] }
        return value.split(separator: ";", omittingEmptySubsequences: false).map { field in
            guard !field.isEmpty, field.allSatisfy(\.isNumber) else { return nil }
            return Int(field)
        }
    }
}

private struct IncrementalUTF8Decoder: Sendable {
    enum Result: Sendable {
        case needMore
        case scalar(UnicodeScalar)
        case invalid(reprocess: Bool)
    }

    private var accumulator: UInt32 = 0
    private var expectedContinuations = 0
    private var minimumScalar: UInt32 = 0

    var hasPendingScalar: Bool { expectedContinuations > 0 }

    mutating func consume(_ byte: UInt8) -> Result {
        if expectedContinuations == 0 {
            switch byte {
            case 0x00...0x7F:
                return .scalar(UnicodeScalar(byte))
            case 0xC2...0xDF:
                accumulator = UInt32(byte & 0x1F)
                expectedContinuations = 1
                minimumScalar = 0x80
                return .needMore
            case 0xE0...0xEF:
                accumulator = UInt32(byte & 0x0F)
                expectedContinuations = 2
                minimumScalar = 0x800
                return .needMore
            case 0xF0...0xF4:
                accumulator = UInt32(byte & 0x07)
                expectedContinuations = 3
                minimumScalar = 0x10000
                return .needMore
            default:
                return .invalid(reprocess: false)
            }
        }

        guard (0x80...0xBF).contains(byte) else {
            reset()
            return .invalid(reprocess: true)
        }
        accumulator = (accumulator << 6) | UInt32(byte & 0x3F)
        expectedContinuations -= 1
        guard expectedContinuations == 0 else { return .needMore }

        let value = accumulator
        let minimum = minimumScalar
        reset()
        guard value >= minimum, value <= 0x10FFFF,
              !(0xD800...0xDFFF).contains(value),
              let scalar = UnicodeScalar(value) else {
            return .invalid(reprocess: false)
        }
        return .scalar(scalar)
    }

    mutating func reset() {
        accumulator = 0
        expectedContinuations = 0
        minimumScalar = 0
    }
}

private struct TerminalLine: Sendable {
    var cells: [TaskTerminalCell]
    var isWrapped = false

    init(columns: Int, style: TaskTerminalTextStyle) {
        cells = Array(repeating: Self.blankCell(style), count: columns)
    }

    var snapshot: TaskTerminalSnapshotLine {
        TaskTerminalSnapshotLine(cells: cells, isWrapped: isWrapped)
    }

    static func blankCell(_ style: TaskTerminalTextStyle) -> TaskTerminalCell {
        TaskTerminalCell(text: "", width: 1, style: style)
    }

    mutating func normalizeWideCells(style: TaskTerminalTextStyle) {
        guard !cells.isEmpty else { return }
        for index in cells.indices {
            if cells[index].isContinuation {
                guard index > 0, cells[index - 1].width == 2 else {
                    cells[index] = Self.blankCell(style)
                    continue
                }
            } else if cells[index].width == 2 {
                guard index + 1 < cells.count else {
                    cells[index] = Self.blankCell(style)
                    continue
                }
                cells[index + 1] = TaskTerminalCell(
                    text: "", width: 0, style: cells[index].style
                )
            }
        }
    }
}

private struct SavedCursor: Sendable {
    var row = 0
    var column = 0
    var style = TaskTerminalTextStyle()
}

private struct ScreenState: Sendable {
    var rows: Int
    var columns: Int
    var lines: [TerminalLine]
    var cursorRow = 0
    var cursorColumn = 0
    var cursorVisible = true
    var style: TaskTerminalTextStyle
    var savedCursor = SavedCursor()
    var scrollTop = 0
    var scrollBottom: Int
    var originMode = false
    var autowrapMode = true
    var insertMode = false
    var newlineMode = false
    var wrapPending = false
    var tabStops: Set<Int>

    init(rows: Int, columns: Int, style: TaskTerminalTextStyle) {
        self.rows = rows
        self.columns = columns
        self.style = style
        lines = (0..<rows).map { _ in TerminalLine(columns: columns, style: style) }
        scrollBottom = rows - 1
        tabStops = Set(stride(from: 8, to: columns, by: 8))
    }

    mutating func resize(
        rows newRows: Int,
        columns newColumns: Int,
        removedFromTop: inout [TerminalLine]
    ) {
        if newColumns != columns {
            for index in lines.indices {
                if lines[index].cells.count > newColumns {
                    lines[index].cells.removeLast(lines[index].cells.count - newColumns)
                } else if lines[index].cells.count < newColumns {
                    lines[index].cells.append(
                        contentsOf: Array(
                            repeating: TerminalLine.blankCell(style),
                            count: newColumns - lines[index].cells.count
                        )
                    )
                }
                lines[index].normalizeWideCells(style: style)
            }
        }
        if newRows < rows {
            let removeCount = rows - newRows
            removedFromTop.append(contentsOf: lines.prefix(removeCount))
            lines.removeFirst(removeCount)
            cursorRow = max(0, cursorRow - removeCount)
        } else if newRows > rows {
            lines.append(
                contentsOf: (0..<(newRows - rows)).map { _ in
                    TerminalLine(columns: newColumns, style: style)
                }
            )
        }
        rows = newRows
        columns = newColumns
        cursorRow = min(cursorRow, rows - 1)
        cursorColumn = min(cursorColumn, columns - 1)
        savedCursor.row = min(savedCursor.row, rows - 1)
        savedCursor.column = min(savedCursor.column, columns - 1)
        scrollTop = 0
        scrollBottom = rows - 1
        wrapPending = false
        tabStops = Set(stride(from: 8, to: columns, by: 8))
    }

    mutating func write(_ text: String, width proposedWidth: Int) -> TerminalLine? {
        let width = min(max(1, proposedWidth), columns)
        var removed: TerminalLine?
        if wrapPending {
            lines[cursorRow].isWrapped = true
            carriageReturn()
            removed = lineFeed(softWrapped: true)
        } else if width > columns - cursorColumn, autowrapMode {
            lines[cursorRow].isWrapped = true
            carriageReturn()
            removed = lineFeed(softWrapped: true)
        }

        let actualWidth = min(width, columns - cursorColumn)
        guard actualWidth > 0 else { return removed }
        clearWideCell(at: cursorColumn)
        if actualWidth == 2 { clearWideCell(at: cursorColumn + 1) }

        if insertMode {
            let shift = actualWidth
            var line = lines[cursorRow]
            line.cells.insert(
                contentsOf: Array(repeating: TerminalLine.blankCell(style), count: shift),
                at: cursorColumn
            )
            line.cells.removeLast(shift)
            line.normalizeWideCells(style: style)
            lines[cursorRow] = line
        }

        lines[cursorRow].cells[cursorColumn] = TaskTerminalCell(
            text: text,
            width: UInt8(actualWidth),
            style: style
        )
        if actualWidth == 2 {
            lines[cursorRow].cells[cursorColumn + 1] = TaskTerminalCell(
                text: "", width: 0, style: style
            )
        }
        if cursorColumn + actualWidth >= columns {
            cursorColumn = columns - 1
            wrapPending = autowrapMode
        } else {
            cursorColumn += actualWidth
            wrapPending = false
        }
        return removed
    }

    mutating func appendToPreviousCell(_ value: String) -> Bool {
        guard let location = previousLeadingCellLocation() else { return false }
        lines[location.row].cells[location.column].text += value
        return true
    }

    func previousLeadingCell() -> TaskTerminalCell? {
        guard let location = previousLeadingCellLocation() else { return nil }
        return lines[location.row].cells[location.column]
    }

    private func previousLeadingCellLocation() -> (row: Int, column: Int)? {
        var row = cursorRow
        var column: Int
        if wrapPending {
            column = cursorColumn
        } else if cursorColumn > 0 {
            column = cursorColumn - 1
        } else if row > 0, lines[row - 1].isWrapped {
            row -= 1
            column = columns - 1
        } else {
            return nil
        }
        while column > 0, lines[row].cells[column].isContinuation { column -= 1 }
        return lines[row].cells[column].isContinuation ? nil : (row, column)
    }

    mutating func lineFeed(softWrapped: Bool) -> TerminalLine? {
        lines[cursorRow].isWrapped = softWrapped
        wrapPending = false
        if newlineMode { cursorColumn = 0 }
        if cursorRow == scrollBottom {
            return scrollUpOne()
        }
        cursorRow = min(rows - 1, cursorRow + 1)
        return nil
    }

    mutating func reverseIndex() {
        wrapPending = false
        if cursorRow == scrollTop {
            _ = scrollDown(1)
        } else {
            cursorRow = max(scrollTop, cursorRow - 1)
        }
    }

    mutating func carriageReturn() {
        cursorColumn = 0
        wrapPending = false
    }

    mutating func backspace() {
        cursorColumn = max(0, cursorColumn - 1)
        if lines[cursorRow].cells[cursorColumn].isContinuation {
            cursorColumn = max(0, cursorColumn - 1)
        }
        wrapPending = false
    }

    mutating func horizontalTab() { forwardTabs(1) }

    mutating func forwardTabs(_ count: Int) {
        for _ in 0..<min(max(1, count), columns) {
            cursorColumn = tabStops.filter { $0 > cursorColumn }.min() ?? (columns - 1)
        }
        wrapPending = false
    }

    mutating func backwardTabs(_ count: Int) {
        for _ in 0..<min(max(1, count), columns) {
            cursorColumn = tabStops.filter { $0 < cursorColumn }.max() ?? 0
        }
        wrapPending = false
    }

    mutating func setTabStop() { tabStops.insert(cursorColumn) }

    mutating func clearTabStops(mode: Int) {
        if mode == 0 { tabStops.remove(cursorColumn) }
        if mode == 3 { tabStops.removeAll() }
    }

    mutating func moveCursor(rows rowDelta: Int, columns columnDelta: Int) {
        let minimumRow = originMode ? scrollTop : 0
        let maximumRow = originMode ? scrollBottom : rows - 1
        cursorRow = min(maximumRow, max(minimumRow, cursorRow + rowDelta))
        cursorColumn = min(columns - 1, max(0, cursorColumn + columnDelta))
        wrapPending = false
    }

    mutating func setCursor(row: Int, column: Int) {
        let adjustedRow = originMode ? scrollTop + row : row
        let maximumRow = originMode ? scrollBottom : rows - 1
        cursorRow = min(maximumRow, max(originMode ? scrollTop : 0, adjustedRow))
        cursorColumn = min(columns - 1, max(0, column))
        wrapPending = false
    }

    mutating func setCursorRow(_ row: Int) { setCursor(row: row, column: cursorColumn) }

    mutating func setCursorColumn(_ column: Int) {
        cursorColumn = min(columns - 1, max(0, column))
        wrapPending = false
    }

    mutating func saveCursor() {
        savedCursor = SavedCursor(row: cursorRow, column: cursorColumn, style: style)
    }

    mutating func restoreCursor() {
        cursorRow = min(rows - 1, max(0, savedCursor.row))
        cursorColumn = min(columns - 1, max(0, savedCursor.column))
        style = savedCursor.style
        wrapPending = false
    }

    mutating func setScrollRegion(top: Int, bottom: Int) {
        guard top >= 0, bottom < rows, top < bottom else { return }
        scrollTop = top
        scrollBottom = bottom
        setCursor(row: 0, column: 0)
    }

    mutating func eraseDisplay(mode: Int) {
        switch mode {
        case 0:
            eraseLine(mode: 0)
            if cursorRow + 1 < rows {
                for row in (cursorRow + 1)..<rows { erase(row: row, range: 0..<columns) }
            }
        case 1:
            if cursorRow > 0 {
                for row in 0..<cursorRow { erase(row: row, range: 0..<columns) }
            }
            eraseLine(mode: 1)
        case 2, 3:
            for row in 0..<rows { erase(row: row, range: 0..<columns) }
        default:
            break
        }
        wrapPending = false
    }

    mutating func eraseLine(mode: Int) {
        switch mode {
        case 0: erase(row: cursorRow, range: cursorColumn..<columns)
        case 1: erase(row: cursorRow, range: 0...cursorColumn)
        case 2: erase(row: cursorRow, range: 0..<columns)
        default: break
        }
        wrapPending = false
    }

    mutating func eraseCharacters(_ count: Int) {
        erase(row: cursorRow, range: cursorColumn..<min(columns, cursorColumn + max(1, count)))
        wrapPending = false
    }

    mutating func insertCharacters(_ count: Int) {
        let amount = min(max(1, count), columns - cursorColumn)
        lines[cursorRow].cells.insert(
            contentsOf: Array(repeating: TerminalLine.blankCell(style), count: amount),
            at: cursorColumn
        )
        lines[cursorRow].cells.removeLast(amount)
        lines[cursorRow].normalizeWideCells(style: style)
        wrapPending = false
    }

    mutating func deleteCharacters(_ count: Int) {
        let amount = min(max(1, count), columns - cursorColumn)
        lines[cursorRow].cells.removeSubrange(cursorColumn..<(cursorColumn + amount))
        lines[cursorRow].cells.append(
            contentsOf: Array(repeating: TerminalLine.blankCell(style), count: amount)
        )
        lines[cursorRow].normalizeWideCells(style: style)
        wrapPending = false
    }

    mutating func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        let amount = min(max(1, count), scrollBottom - cursorRow + 1)
        for _ in 0..<amount {
            lines.insert(TerminalLine(columns: columns, style: style), at: cursorRow)
            lines.remove(at: scrollBottom + 1)
        }
        wrapPending = false
    }

    mutating func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        let amount = min(max(1, count), scrollBottom - cursorRow + 1)
        for _ in 0..<amount {
            lines.remove(at: cursorRow)
            lines.insert(TerminalLine(columns: columns, style: style), at: scrollBottom)
        }
        wrapPending = false
    }

    mutating func scrollUp(_ count: Int) -> [TerminalLine] {
        var removed: [TerminalLine] = []
        for _ in 0..<min(max(1, count), scrollBottom - scrollTop + 1) {
            if let line = scrollUpOne() { removed.append(line) }
        }
        return removed
    }

    @discardableResult
    mutating func scrollDown(_ count: Int) -> [TerminalLine] {
        var discarded: [TerminalLine] = []
        for _ in 0..<min(max(1, count), scrollBottom - scrollTop + 1) {
            discarded.append(lines.remove(at: scrollBottom))
            lines.insert(TerminalLine(columns: columns, style: style), at: scrollTop)
        }
        wrapPending = false
        return discarded
    }

    private mutating func scrollUpOne() -> TerminalLine? {
        let removed = lines.remove(at: scrollTop)
        lines.insert(TerminalLine(columns: columns, style: style), at: scrollBottom)
        wrapPending = false
        return scrollTop == 0 && scrollBottom == rows - 1 ? removed : nil
    }

    private mutating func erase<R: RangeExpression>(row: Int, range: R)
    where R.Bound == Int {
        let concrete = range.relative(to: lines[row].cells)
        guard !concrete.isEmpty else { return }
        var expandedLower = concrete.lowerBound
        var expandedUpper = concrete.upperBound
        if expandedLower < columns, lines[row].cells[expandedLower].isContinuation {
            expandedLower = max(0, expandedLower - 1)
        }
        if expandedUpper < columns, lines[row].cells[expandedUpper].isContinuation {
            expandedUpper = min(columns, expandedUpper + 1)
        }
        for column in expandedLower..<expandedUpper {
            lines[row].cells[column] = TerminalLine.blankCell(style)
        }
        lines[row].isWrapped = false
    }

    private mutating func clearWideCell(at column: Int) {
        guard (0..<columns).contains(column) else { return }
        if lines[cursorRow].cells[column].isContinuation {
            lines[cursorRow].cells[column] = TerminalLine.blankCell(style)
            if column > 0 { lines[cursorRow].cells[column - 1] = TerminalLine.blankCell(style) }
        } else if lines[cursorRow].cells[column].width == 2 {
            lines[cursorRow].cells[column] = TerminalLine.blankCell(style)
            if column + 1 < columns {
                lines[cursorRow].cells[column + 1] = TerminalLine.blankCell(style)
            }
        }
    }
}

private struct LineRing: Sendable {
    private var storage: [TerminalLine?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(0, capacity))
    }

    var elements: [TerminalLine] {
        guard !storage.isEmpty, count > 0 else { return [] }
        return (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    mutating func append(_ line: TerminalLine) {
        guard !storage.isEmpty else { return }
        if count < storage.count {
            storage[(head + count) % storage.count] = line
            count += 1
        } else {
            storage[head] = line
            head = (head + 1) % storage.count
        }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: storage.count)
        head = 0
        count = 0
    }

    mutating func setCapacity(_ capacity: Int) {
        let retained = Array(elements.suffix(max(0, capacity)))
        storage = Array(repeating: nil, count: max(0, capacity))
        head = 0
        count = 0
        for line in retained { append(line) }
    }
}

private extension TaskTerminalSnapshotLine {
    func column(atUTF16Offset target: Int) -> Int {
        guard target > 0 else { return 0 }
        var offset = 0
        for (column, cell) in cells.enumerated() where !cell.isContinuation {
            let text = cell.text.isEmpty ? " " : cell.text
            let next = offset + (text as NSString).length
            if target <= offset { return column }
            if target <= next { return min(cells.count, column + Int(cell.width)) }
            offset = next
        }
        return cells.count
    }

    func text(inColumns range: Range<Int>) -> String {
        guard !range.isEmpty else { return "" }
        var value = ""
        for (column, cell) in cells.enumerated() where !cell.isContinuation {
            let end = column + Int(cell.width)
            if column < range.upperBound, end > range.lowerBound {
                value += cell.text.isEmpty ? " " : cell.text
            }
        }
        return value
    }
}

private extension String {
    func trimmingTrailingSpaces() -> String {
        var value = self
        while value.last == " " { value.removeLast() }
        return value
    }
}

private extension BidirectionalCollection {
    func drop(whileFromEnd predicate: (Element) throws -> Bool) rethrows -> SubSequence {
        var end = endIndex
        while end != startIndex {
            let previous = index(before: end)
            guard try predicate(self[previous]) else { break }
            end = previous
        }
        return self[startIndex..<end]
    }
}
