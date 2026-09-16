import AppKit
import SwiftUI

@MainActor
struct TaskTerminalSurfaceView: NSViewRepresentable {
    var snapshot: TaskTerminalSnapshot
    var applicationCursorKeys: Bool
    var bracketedPaste: Bool
    var searchText: String
    var searchRequest: UInt64
    var copyRequest: UInt64
    var onInput: (Data) -> Void
    var onResize: (_ rows: Int, _ columns: Int) -> Void
    var onRequestSearch: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TaskTerminalScrollView {
        let scrollView = TaskTerminalScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let contentSize = scrollView.contentSize
        let textView = TaskTerminalTextView(
            frame: NSRect(origin: .zero, size: contentSize)
        )
        textView.font = context.coordinator.font
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFindPanel = false
        textView.usesFontPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.installCallbacks()

        context.coordinator.viewportDidChange(scrollView.contentSize)
        return scrollView
    }

    func updateNSView(_ scrollView: TaskTerminalScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onInput = onInput
        coordinator.onResize = onResize
        coordinator.onRequestSearch = onRequestSearch
        coordinator.applicationCursorKeys = applicationCursorKeys
        coordinator.bracketedPaste = bracketedPaste

        coordinator.update(snapshot: snapshot)
        coordinator.updateSearch(text: searchText, request: searchRequest)
        coordinator.updateCopyRequest(copyRequest)
        coordinator.viewportDidChange(scrollView.contentSize)
    }

    @MainActor
    final class Coordinator: NSObject {
        fileprivate weak var textView: TaskTerminalTextView?
        fileprivate weak var scrollView: TaskTerminalScrollView?
        fileprivate var onInput: ((Data) -> Void)?
        fileprivate var onResize: ((Int, Int) -> Void)?
        fileprivate var onRequestSearch: (() -> Void)?
        fileprivate var applicationCursorKeys = false
        fileprivate var bracketedPaste = false

        fileprivate let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        private var lastSnapshot: TaskTerminalSnapshot?
        private var lastSearchText = ""
        private var lastSearchRequest: UInt64 = 0
        private var lastCopyRequest: UInt64 = 0
        private var lastDimensions: (rows: Int, columns: Int)?
        private var resizeTask: Task<Void, Never>?

        fileprivate func installCallbacks() {
            textView?.onKeyData = { [weak self] event in
                self?.encodedKeyData(for: event) ?? false
            }
            textView?.onPaste = { [weak self] string in
                self?.paste(string)
            }
            textView?.onRequestSearch = { [weak self] in
                self?.onRequestSearch?()
            }
            scrollView?.onViewportChange = { [weak self] size in
                self?.viewportDidChange(size)
            }
        }

        fileprivate func update(snapshot: TaskTerminalSnapshot) {
            guard snapshot != lastSnapshot, let textView, let scrollView else { return }
            let rendered = Self.render(snapshot)
            let documentHeight = textView.bounds.height
            let visibleBottom = scrollView.contentView.bounds.maxY
            let wasAtBottom = documentHeight <= scrollView.contentSize.height
                || visibleBottom >= documentHeight - 24
            let selection = textView.selectedRange()
            let wasSelecting = selection.length > 0

            textView.textStorage?.setAttributedString(rendered.attributedText)
            let renderedText = rendered.attributedText.string
            if wasSelecting {
                let safeLocation = min(selection.location, (renderedText as NSString).length)
                let safeLength = min(
                    selection.length,
                    (renderedText as NSString).length - safeLocation
                )
                textView.setSelectedRange(NSRange(location: safeLocation, length: safeLength))
            } else {
                let cursor = min(rendered.cursorUTF16Offset, (renderedText as NSString).length)
                textView.setSelectedRange(NSRange(location: cursor, length: 0))
            }
            lastSnapshot = snapshot

            if wasAtBottom {
                textView.scrollRangeToVisible(
                    NSRange(location: (renderedText as NSString).length, length: 0)
                )
            }
        }

        static func render(_ snapshot: TaskTerminalSnapshot) -> (
            attributedText: NSAttributedString,
            cursorUTF16Offset: Int
        ) {
            let lines = snapshot.allLines
            let cursorLine = snapshot.scrollback.count + snapshot.cursor.row
            let output = NSMutableAttributedString(string: "")
            var cursorOffset = 0
            var cursorLength = 0
            let defaultAttributes = styleAttributes(.init())

            for (lineIndex, line) in lines.enumerated() {
                let preserveColumns = lineIndex >= snapshot.scrollback.count
                let finalIncludedColumn: Int
                if preserveColumns {
                    finalIncludedColumn = line.cells.count - 1
                } else {
                    finalIncludedColumn = line.cells.lastIndex(where: { cell in
                        !cell.isContinuation
                            && !displayText(for: cell).allSatisfy { $0 == " " }
                    }) ?? -1
                }

                if lineIndex == cursorLine {
                    let prefix = line.cells.prefix(max(0, snapshot.cursor.column))
                        .filter { !$0.isContinuation }
                        .map(displayText(for:))
                        .joined()
                    cursorOffset = output.length + (prefix as NSString).length
                    if line.cells.indices.contains(snapshot.cursor.column) {
                        let cell = line.cells[snapshot.cursor.column]
                        if cell.isContinuation, snapshot.cursor.column > 0 {
                            let leadingLength = (displayText(
                                for: line.cells[snapshot.cursor.column - 1]
                            ) as NSString).length
                            cursorOffset = max(output.length, cursorOffset - leadingLength)
                            cursorLength = leadingLength
                        } else {
                            cursorLength = (displayText(for: cell) as NSString).length
                        }
                    }
                }

                if finalIncludedColumn >= 0 {
                    for (column, cell) in line.cells.enumerated()
                    where column <= finalIncludedColumn && !cell.isContinuation {
                        output.append(NSAttributedString(
                            string: displayText(for: cell),
                            attributes: styleAttributes(cell.style)
                        ))
                    }
                }
                if lineIndex < lines.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: defaultAttributes))
                }
            }
            if snapshot.cursor.isVisible,
               cursorLength > 0,
               cursorOffset >= 0,
               cursorOffset < output.length {
                let length = min(cursorLength, output.length - cursorOffset)
                output.addAttributes([
                    .backgroundColor: NSColor.selectedTextBackgroundColor.withAlphaComponent(0.72),
                    .foregroundColor: NSColor.selectedTextColor
                ], range: NSRange(location: cursorOffset, length: length))
            }
            return (NSAttributedString(attributedString: output), cursorOffset)
        }

        private static func displayText(for cell: TaskTerminalCell) -> String {
            if cell.style.attributes.contains(.hidden) {
                return String(repeating: " ", count: max(1, Int(cell.width)))
            }
            return cell.text.isEmpty
                ? String(repeating: " ", count: max(1, Int(cell.width)))
                : cell.text
        }

        private static func styleAttributes(
            _ style: TaskTerminalTextStyle
        ) -> [NSAttributedString.Key: Any] {
            let inverse = style.attributes.contains(.inverse)
            var foreground = terminalColor(
                inverse ? style.background : style.foreground,
                defaultColor: inverse ? .textBackgroundColor : .textColor
            )
            let background = terminalColor(
                inverse ? style.foreground : style.background,
                defaultColor: inverse ? .textColor : .textBackgroundColor
            )
            if style.attributes.contains(.dim) {
                foreground = foreground.withAlphaComponent(0.62)
            }

            var traits: NSFontTraitMask = []
            if style.attributes.contains(.bold) { traits.insert(.boldFontMask) }
            if style.attributes.contains(.italic) { traits.insert(.italicFontMask) }
            let renderedFont = traits.isEmpty
                ? NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                : NSFontManager.shared.convert(
                    NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    toHaveTrait: traits
                )
            var attributes: [NSAttributedString.Key: Any] = [
                .font: renderedFont,
                .foregroundColor: foreground
            ]
            if inverse || style.background != .default {
                attributes[.backgroundColor] = background
            }
            if style.attributes.contains(.underline) {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if style.attributes.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attributes
        }

        private static func terminalColor(
            _ color: TaskTerminalColor,
            defaultColor: NSColor
        ) -> NSColor {
            switch color {
            case .default:
                return defaultColor
            case .rgb(let red, let green, let blue):
                return NSColor(
                    srgbRed: CGFloat(red) / 255,
                    green: CGFloat(green) / 255,
                    blue: CGFloat(blue) / 255,
                    alpha: 1
                )
            case .indexed(let index):
                return indexedColor(index)
            }
        }

        private static func indexedColor(_ index: UInt8) -> NSColor {
            let base: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16),
                (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
                (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67),
                (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)
            ]
            let components: (UInt8, UInt8, UInt8)
            if index < 16 {
                components = base[Int(index)]
            } else if index < 232 {
                let value = Int(index) - 16
                let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
                components = (
                    levels[value / 36],
                    levels[(value / 6) % 6],
                    levels[value % 6]
                )
            } else {
                let level = UInt8(8 + (Int(index) - 232) * 10)
                components = (level, level, level)
            }
            return NSColor(
                srgbRed: CGFloat(components.0) / 255,
                green: CGFloat(components.1) / 255,
                blue: CGFloat(components.2) / 255,
                alpha: 1
            )
        }

        fileprivate func updateSearch(text: String, request: UInt64) {
            let queryChanged = text != lastSearchText
            let requestChanged = request != lastSearchRequest
            lastSearchText = text
            lastSearchRequest = request
            guard (queryChanged || requestChanged), !text.isEmpty else { return }
            findNext(text)
        }

        fileprivate func updateCopyRequest(_ request: UInt64) {
            guard request != lastCopyRequest, let textView else { return }
            lastCopyRequest = request
            let selection = textView.selectedRange()
            let value: String
            if selection.length > 0 {
                value = (textView.string as NSString).substring(with: selection)
            } else {
                value = textView.string
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(value, forType: .string)
        }

        fileprivate func viewportDidChange(_ size: NSSize) {
            let glyph = ("M" as NSString).size(withAttributes: [.font: font])
            let lineHeight = ceil(font.ascender - font.descender + font.leading)
            let columns = max(1, min(1_000, Int((size.width - 16) / max(glyph.width, 1))))
            let rows = max(1, min(1_000, Int((size.height - 14) / max(lineHeight, 1))))
            guard lastDimensions?.rows != rows || lastDimensions?.columns != columns else {
                return
            }
            lastDimensions = (rows, columns)
            resizeTask?.cancel()
            resizeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                guard let self,
                      self.lastDimensions?.rows == rows,
                      self.lastDimensions?.columns == columns else { return }
                self.onResize?(rows, columns)
            }
        }

        private func findNext(_ query: String) {
            guard let textView else { return }
            let source = textView.string as NSString
            guard source.length > 0 else { return }
            let start = min(NSMaxRange(textView.selectedRange()), source.length)
            let tail = NSRange(location: start, length: source.length - start)
            var match = source.range(of: query, options: [.caseInsensitive], range: tail)
            if match.location == NSNotFound, start > 0 {
                match = source.range(
                    of: query,
                    options: [.caseInsensitive],
                    range: NSRange(location: 0, length: start)
                )
            }
            guard match.location != NSNotFound else {
                NSSound.beep()
                return
            }
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.window?.makeFirstResponder(textView)
        }

        private func paste(_ string: String) {
            var data = Data(string.utf8)
            if bracketedPaste {
                var wrapped = Data("\u{1b}[200~".utf8)
                wrapped.append(data)
                wrapped.append(Data("\u{1b}[201~".utf8))
                data = wrapped
            }
            onInput?(data)
        }

        private func encodedKeyData(for event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let command = modifiers.contains(.command)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if command {
                if key == "f" {
                    onRequestSearch?()
                    return true
                }
                return false
            }

            let sequence: [UInt8]?
            switch event.keyCode {
            case 36, 76: sequence = [0x0d] // Return / keypad Enter
            case 48: sequence = [0x09]
            case 51: sequence = [0x7f]
            case 53: sequence = [0x1b]
            case 117: sequence = Array("\u{1b}[3~".utf8)
            case 123: sequence = Array((applicationCursorKeys ? "\u{1b}OD" : "\u{1b}[D").utf8)
            case 124: sequence = Array((applicationCursorKeys ? "\u{1b}OC" : "\u{1b}[C").utf8)
            case 125: sequence = Array((applicationCursorKeys ? "\u{1b}OB" : "\u{1b}[B").utf8)
            case 126: sequence = Array((applicationCursorKeys ? "\u{1b}OA" : "\u{1b}[A").utf8)
            case 115: sequence = Array("\u{1b}[H".utf8)
            case 119: sequence = Array("\u{1b}[F".utf8)
            case 116: sequence = Array("\u{1b}[5~".utf8)
            case 121: sequence = Array("\u{1b}[6~".utf8)
            case 122: sequence = Array("\u{1b}OP".utf8)
            case 120: sequence = Array("\u{1b}OQ".utf8)
            case 99: sequence = Array("\u{1b}OR".utf8)
            case 118: sequence = Array("\u{1b}OS".utf8)
            case 96: sequence = Array("\u{1b}[15~".utf8)
            case 97: sequence = Array("\u{1b}[17~".utf8)
            case 98: sequence = Array("\u{1b}[18~".utf8)
            case 100: sequence = Array("\u{1b}[19~".utf8)
            case 101: sequence = Array("\u{1b}[20~".utf8)
            case 109: sequence = Array("\u{1b}[21~".utf8)
            case 103: sequence = Array("\u{1b}[23~".utf8)
            case 111: sequence = Array("\u{1b}[24~".utf8)
            default: sequence = nil
            }
            if let sequence {
                onInput?(Data(sequence))
                return true
            }

            if modifiers.contains(.control), let scalar = key.unicodeScalars.first {
                let value = scalar.value
                let control: UInt8?
                switch value {
                case 0x40...0x5f: control = UInt8(value - 0x40)
                case 0x61...0x7a: control = UInt8(value - 0x60)
                default: control = nil
                }
                if let control {
                    onInput?(Data([control]))
                    return true
                }
            }

            guard let characters = event.characters, !characters.isEmpty else { return false }
            onInput?(Data(characters.utf8))
            return true
        }
    }
}

@MainActor
final class TaskTerminalTextView: NSTextView {
    var onKeyData: ((NSEvent) -> Bool)?
    var onPaste: ((String) -> Void)?
    var onRequestSearch: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyData?(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if modifiers.contains(.command), key == "f" {
            onRequestSearch?()
            return true
        }
        if modifiers.contains(.command), key == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let value = NSPasteboard.general.string(forType: .string) else { return }
        onPaste?(value)
    }
}

@MainActor
final class TaskTerminalScrollView: NSScrollView {
    var onViewportChange: ((NSSize) -> Void)?

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onViewportChange?(contentSize)
    }
}
