import Foundation

enum UnifiedDiffError: LocalizedError, Sendable {
    case malformed(String)
    case unsafePath(String)
    case contextMismatch(path: String, line: Int)
    case limitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "Malformed unified diff: \(detail)"
        case .unsafePath(let path):
            "Patch path is not workspace-relative: \(path)"
        case .contextMismatch(let path, let line):
            "Patch context did not match \(path) near line \(line)."
        case .limitExceeded(let detail):
            "Unified diff exceeded its safety limit: \(detail)"
        }
    }
}

struct UnifiedFilePatch: Sendable, Equatable {
    var oldPath: String?
    var newPath: String?
    var hunks: [UnifiedDiffHunk]

    var effectivePath: String { newPath ?? oldPath ?? "" }
}

struct UnifiedDiffHunk: Sendable, Equatable {
    var oldStart: Int
    var oldCount: Int
    var newStart: Int
    var newCount: Int
    var lines: [UnifiedDiffLine]
}

enum UnifiedDiffLine: Sendable, Equatable {
    case context(String)
    case removal(String)
    case addition(String)
}

struct UnifiedDiffParser: Sendable {
    private static let maximumInputBytes = 4 * 1_024 * 1_024
    private static let maximumLines = 200_000
    private static let maximumFiles = 256
    private static let hunkExpression = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
    )

    func parse(_ text: String) throws -> [UnifiedFilePatch] {
        guard text.utf8.count <= Self.maximumInputBytes else {
            throw UnifiedDiffError.limitExceeded("input is larger than 4 MiB")
        }
        guard text.utf8.lazy.filter({ $0 == 0x0A }).count <= Self.maximumLines else {
            throw UnifiedDiffError.limitExceeded("input has more than 200,000 lines")
        }
        let lines = text.components(separatedBy: .newlines)
        var patches: [UnifiedFilePatch] = []
        var index = 0

        while index < lines.count {
            if Task.isCancelled { throw CancellationError() }
            guard lines[index].hasPrefix("--- ") else {
                index += 1
                continue
            }

            let oldPath = try parsePath(String(lines[index].dropFirst(4)))
            index += 1
            guard index < lines.count, lines[index].hasPrefix("+++ ") else {
                throw UnifiedDiffError.malformed("missing +++ header")
            }
            let newPath = try parsePath(String(lines[index].dropFirst(4)))
            index += 1

            var hunks: [UnifiedDiffHunk] = []
            while index < lines.count, !lines[index].hasPrefix("--- ") {
                guard lines[index].hasPrefix("@@") else {
                    index += 1
                    continue
                }
                let header = lines[index]
                let range = NSRange(header.startIndex..<header.endIndex, in: header)
                guard let match = Self.hunkExpression.firstMatch(in: header, range: range) else {
                    throw UnifiedDiffError.malformed("invalid hunk header: \(header)")
                }

                func integer(at capture: Int, default defaultValue: Int) -> Int {
                    let range = match.range(at: capture)
                    guard range.location != NSNotFound,
                          let swiftRange = Range(range, in: header)
                    else { return defaultValue }
                    return Int(header[swiftRange]) ?? defaultValue
                }

                let oldStart = integer(at: 1, default: 0)
                let oldCount = integer(at: 2, default: 1)
                let newStart = integer(at: 3, default: 0)
                let newCount = integer(at: 4, default: 1)
                index += 1

                var hunkLines: [UnifiedDiffLine] = []
                var consumedOld = 0
                var consumedNew = 0
                while index < lines.count,
                      consumedOld < oldCount || consumedNew < newCount {
                    if Task.isCancelled { throw CancellationError() }
                    let line = lines[index]
                    if line == #"\ No newline at end of file"# {
                        index += 1
                        continue
                    }
                    guard let marker = line.first else {
                        throw UnifiedDiffError.malformed("an empty diff line needs a prefix")
                    }
                    let value = String(line.dropFirst())
                    switch marker {
                    case " ":
                        hunkLines.append(.context(value))
                        consumedOld += 1
                        consumedNew += 1
                    case "-":
                        hunkLines.append(.removal(value))
                        consumedOld += 1
                    case "+":
                        hunkLines.append(.addition(value))
                        consumedNew += 1
                    default:
                        throw UnifiedDiffError.malformed("unexpected hunk marker: \(marker)")
                    }
                    index += 1
                }
                guard consumedOld == oldCount, consumedNew == newCount else {
                    throw UnifiedDiffError.malformed("hunk line counts do not match its header")
                }
                hunks.append(UnifiedDiffHunk(
                    oldStart: oldStart,
                    oldCount: oldCount,
                    newStart: newStart,
                    newCount: newCount,
                    lines: hunkLines
                ))
            }

            guard !hunks.isEmpty else {
                throw UnifiedDiffError.malformed("file patch has no hunks")
            }
            patches.append(UnifiedFilePatch(oldPath: oldPath, newPath: newPath, hunks: hunks))
            guard patches.count <= Self.maximumFiles else {
                throw UnifiedDiffError.limitExceeded("input has more than 256 file patches")
            }
        }

        guard !patches.isEmpty else {
            throw UnifiedDiffError.malformed("no file headers found")
        }
        return patches
    }

    private func parsePath(_ rawValue: String) throws -> String? {
        var value = rawValue.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? rawValue
        value = value.trimmingCharacters(in: .whitespaces)
        if value == "/dev/null" { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value.removeFirst(2)
        }
        let components = NSString(string: value).pathComponents
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !components.contains(".."),
              !components.contains("~")
        else {
            throw UnifiedDiffError.unsafePath(value)
        }
        return value
    }
}

struct UnifiedDiffApplier: Sendable {
    func apply(_ patch: UnifiedFilePatch, to source: String) throws -> String {
        let maximumSourceBytes = 8 * 1_024 * 1_024
        let maximumOutputBytes = 16 * 1_024 * 1_024
        let maximumLines = 200_000
        guard source.utf8.count <= maximumSourceBytes else {
            throw UnifiedDiffError.limitExceeded("source is larger than 8 MiB")
        }
        guard source.utf8.lazy.filter({ $0 == 0x0A }).count <= maximumLines,
              patch.hunks.reduce(0, { $0 + $1.lines.count }) <= maximumLines else {
            throw UnifiedDiffError.limitExceeded("source or patch has more than 200,000 lines")
        }
        let sourceHadTrailingNewline = source.hasSuffix("\n")
        var sourceLines = source.isEmpty ? [] : source.components(separatedBy: "\n")
        if sourceHadTrailingNewline { sourceLines.removeLast() }

        var output: [String] = []
        var sourceIndex = 0

        for hunk in patch.hunks {
            if Task.isCancelled { throw CancellationError() }
            let expectedIndex = max(0, hunk.oldStart - 1)
            guard expectedIndex >= sourceIndex, expectedIndex <= sourceLines.count else {
                throw UnifiedDiffError.contextMismatch(path: patch.effectivePath, line: hunk.oldStart)
            }
            output.append(contentsOf: sourceLines[sourceIndex..<expectedIndex])
            sourceIndex = expectedIndex

            for line in hunk.lines {
                if Task.isCancelled { throw CancellationError() }
                switch line {
                case .addition(let value):
                    output.append(value)
                case .context(let value):
                    guard sourceIndex < sourceLines.count, sourceLines[sourceIndex] == value else {
                        throw UnifiedDiffError.contextMismatch(
                            path: patch.effectivePath,
                            line: sourceIndex + 1
                        )
                    }
                    output.append(value)
                    sourceIndex += 1
                case .removal(let value):
                    guard sourceIndex < sourceLines.count, sourceLines[sourceIndex] == value else {
                        throw UnifiedDiffError.contextMismatch(
                            path: patch.effectivePath,
                            line: sourceIndex + 1
                        )
                    }
                    sourceIndex += 1
                }
            }
        }
        output.append(contentsOf: sourceLines[sourceIndex...])

        var outputBytes = max(0, output.count - 1) // newline separators
        for line in output {
            let count = line.utf8.count
            guard count <= maximumOutputBytes - min(outputBytes, maximumOutputBytes) else {
                throw UnifiedDiffError.limitExceeded("patched output is larger than 16 MiB")
            }
            outputBytes += count
        }
        if sourceHadTrailingNewline || patch.oldPath == nil { outputBytes += 1 }
        guard outputBytes <= maximumOutputBytes else {
            throw UnifiedDiffError.limitExceeded("patched output is larger than 16 MiB")
        }
        var result = output.joined(separator: "\n")
        if sourceHadTrailingNewline || patch.oldPath == nil { result.append("\n") }
        return result
    }
}

struct UnifiedDiffBuilder: Sendable {
    private let contextLineCount = 3
    private let maximumInputBytes = 4 * 1_024 * 1_024
    private let maximumInputLines = 100_000
    private let maximumLineBytes = 256 * 1_024
    private let maximumOutputBytes = 1 * 1_024 * 1_024

    func make(path: String, old: Data?, new: Data?) -> String {
        let safePath = path
            .replacingOccurrences(of: "\n", with: "�")
            .replacingOccurrences(of: "\r", with: "�")
        if let old, old.count > maximumInputBytes {
            return omitted(path: safePath, reason: "old input exceeds 4 MiB")
        }
        if let new, new.count > maximumInputBytes {
            return omitted(path: safePath, reason: "new input exceeds 4 MiB")
        }
        if let old, newlineCount(old) > maximumInputLines {
            return omitted(path: safePath, reason: "old input exceeds 100,000 lines")
        }
        if let new, newlineCount(new) > maximumInputLines {
            return omitted(path: safePath, reason: "new input exceeds 100,000 lines")
        }

        guard let oldText = old.flatMap({ String(data: $0, encoding: .utf8) }),
              let newText = new.flatMap({ String(data: $0, encoding: .utf8) })
        else {
            if old == nil, let newText = new.flatMap({ String(data: $0, encoding: .utf8) }) {
                return makeCreatedFile(path: safePath, text: newText)
            }
            if new == nil, let oldText = old.flatMap({ String(data: $0, encoding: .utf8) }) {
                return makeDeletedFile(path: safePath, text: oldText)
            }
            return "Binary files a/\(safePath) and b/\(safePath) differ\n"
        }
        guard oldText != newText else { return "" }

        let oldLines = normalizedLines(oldText)
        let newLines = normalizedLines(newText)
        guard oldLines.allSatisfy({ $0.utf8.count <= maximumLineBytes }),
              newLines.allSatisfy({ $0.utf8.count <= maximumLineBytes }) else {
            return omitted(path: safePath, reason: "a line exceeds 256 KiB")
        }
        var prefix = 0
        while prefix < min(oldLines.count, newLines.count), oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldLines.count - prefix, newLines.count - prefix),
              oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1] {
            suffix += 1
        }

        let hunkStart = max(0, prefix - contextLineCount)
        let oldEnd = min(oldLines.count, oldLines.count - suffix + contextLineCount)
        let newEnd = min(newLines.count, newLines.count - suffix + contextLineCount)
        let oldCount = oldEnd - hunkStart
        let newCount = newEnd - hunkStart

        var output = BoundedDiffOutput(maximumBytes: maximumOutputBytes)
        output.append("--- a/\(safePath)\n+++ b/\(safePath)\n")
        output.append("@@ -\(hunkStart + 1),\(oldCount) +\(hunkStart + 1),\(newCount) @@\n")
        for line in oldLines[hunkStart..<prefix] {
            output.append(" \(line)\n")
            if output.truncated { break }
        }
        if !output.truncated {
            for line in oldLines[prefix..<(oldLines.count - suffix)] {
                output.append("-\(line)\n")
                if output.truncated { break }
            }
        }
        if !output.truncated {
            for line in newLines[prefix..<(newLines.count - suffix)] {
                output.append("+\(line)\n")
                if output.truncated { break }
            }
        }
        if suffix > 0, !output.truncated {
            let contextStart = max(oldLines.count - suffix, oldLines.count - suffix)
            let count = min(contextLineCount, suffix)
            for line in oldLines[contextStart..<(contextStart + count)] {
                output.append(" \(line)\n")
                if output.truncated { break }
            }
        }
        return output.finished()
    }

    private func makeCreatedFile(path: String, text: String) -> String {
        let lines = normalizedLines(text)
        guard lines.allSatisfy({ $0.utf8.count <= maximumLineBytes }) else {
            return omitted(path: path, reason: "a line exceeds 256 KiB")
        }
        var output = BoundedDiffOutput(maximumBytes: maximumOutputBytes)
        output.append("--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1,\(lines.count) @@\n")
        for line in lines {
            output.append("+\(line)\n")
            if output.truncated { break }
        }
        return output.finished()
    }

    private func makeDeletedFile(path: String, text: String) -> String {
        let lines = normalizedLines(text)
        guard lines.allSatisfy({ $0.utf8.count <= maximumLineBytes }) else {
            return omitted(path: path, reason: "a line exceeds 256 KiB")
        }
        var output = BoundedDiffOutput(maximumBytes: maximumOutputBytes)
        output.append("--- a/\(path)\n+++ /dev/null\n@@ -1,\(lines.count) +0,0 @@\n")
        for line in lines {
            output.append("-\(line)\n")
            if output.truncated { break }
        }
        return output.finished()
    }

    private func normalizedLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private func newlineCount(_ data: Data) -> Int {
        data.lazy.filter { $0 == 0x0A }.count
    }

    private func omitted(path: String, reason: String) -> String {
        "Files a/\(path) and b/\(path) differ (diff omitted: \(reason)).\n"
    }
}

private struct BoundedDiffOutput {
    private(set) var value = ""
    private(set) var truncated = false
    let maximumBytes: Int

    mutating func append(_ fragment: String) {
        guard !truncated else { return }
        let used = value.utf8.count
        let remaining = max(0, maximumBytes - used)
        guard fragment.utf8.count <= remaining else {
            value += String(decoding: fragment.utf8.prefix(remaining), as: UTF8.self)
            truncated = true
            return
        }
        value += fragment
    }

    func finished() -> String {
        guard truncated else { return value }
        let marker = "\n… diff truncated at 1 MiB …\n"
        let markerBytes = marker.utf8.count
        let contentLimit = max(0, maximumBytes - markerBytes)
        return String(decoding: value.utf8.prefix(contentLimit), as: UTF8.self) + marker
    }
}
