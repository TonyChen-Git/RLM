import CryptoKit
import Foundation

enum ReviewDiffParserError: LocalizedError, Equatable, Sendable {
    case malformed(String)
    case unsafePath(String)
    case limitExceeded(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "Malformed review diff: \(detail)"
        case .unsafePath(let path):
            "Review diff path is not workspace-relative: \(path)"
        case .limitExceeded(let detail):
            "Review diff exceeded its display limit: \(detail)"
        }
    }
}

struct ReviewDiffParser: Sendable {
    struct Limits: Equatable, Sendable {
        var maximumDocumentBytes = 16 * 1_024 * 1_024
        var maximumFileBytes = 2 * 1_024 * 1_024
        var maximumFiles = 512
        var maximumHunksPerFile = 4_096
        var maximumLinesPerFile = 200_000
    }

    private struct Segment {
        var lines: [String]
        var byteCount: Int
    }

    private struct Metadata {
        var oldPath: String?
        var newPath: String?
        var renameFrom: String?
        var renameTo: String?
        var isNew = false
        var isDeleted = false
        var isRename = false
        var isUntracked = false
        var fallback: ReviewDiffFallback?
    }

    private static let hunkExpression = try! NSRegularExpression(
        pattern: #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$"#
    )

    private let limits: Limits
    private let highlighter: ReviewSyntaxHighlighter

    init(
        limits: Limits = Limits(),
        highlighter: ReviewSyntaxHighlighter = ReviewSyntaxHighlighter()
    ) {
        self.limits = limits
        self.highlighter = highlighter
    }

    func parse(_ rawDiff: String, source: ReviewSource) throws -> ReviewDocument {
        let documentBytes = rawDiff.utf8.count
        guard documentBytes <= limits.maximumDocumentBytes else {
            throw ReviewDiffParserError.limitExceeded(
                "document is larger than \(limits.maximumDocumentBytes) bytes"
            )
        }
        guard !rawDiff.isEmpty else {
            return ReviewDocument(source: source, files: [], generatedAt: Date())
        }

        let segments = splitIntoFileSegments(rawDiff)
        guard !segments.isEmpty else {
            throw ReviewDiffParserError.malformed("no file diff headers were found")
        }
        guard segments.count <= limits.maximumFiles else {
            throw ReviewDiffParserError.limitExceeded(
                "document has more than \(limits.maximumFiles) files"
            )
        }

        var files: [ReviewFileDiff] = []
        files.reserveCapacity(segments.count)
        for segment in segments {
            if Task.isCancelled { throw CancellationError() }
            files.append(try parse(segment))
        }
        return ReviewDocument(source: source, files: files, generatedAt: Date())
    }

    private func splitIntoFileSegments(_ rawDiff: String) -> [Segment] {
        var lines = rawDiff.components(separatedBy: "\n")
        if rawDiff.hasSuffix("\n") { lines.removeLast() }
        lines = lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        let gitStarts = lines.indices.filter { lines[$0].hasPrefix("diff --git ") }
        if !gitStarts.isEmpty {
            return gitStarts.enumerated().map { offset, start in
                let end = offset + 1 < gitStarts.count ? gitStarts[offset + 1] : lines.count
                return makeSegment(Array(lines[start..<end]))
            }
        }

        var starts: [Int] = []
        var index = 0
        var remainingOld = 0
        var remainingNew = 0
        while index < lines.count {
            let line = lines[index]
            if remainingOld > 0 || remainingNew > 0 {
                if line == #"\ No newline at end of file"# {
                    index += 1
                    continue
                }
                switch line.first {
                case " ":
                    remainingOld = max(0, remainingOld - 1)
                    remainingNew = max(0, remainingNew - 1)
                case "-":
                    remainingOld = max(0, remainingOld - 1)
                case "+":
                    remainingNew = max(0, remainingNew - 1)
                default:
                    // The parser will later expose the malformed hunk as a
                    // display fallback. Here we only avoid mistaking its body
                    // for another file header.
                    break
                }
                index += 1
                continue
            }
            if line.hasPrefix("@@"), let counts = hunkCounts(line) {
                remainingOld = counts.old
                remainingNew = counts.new
                index += 1
                continue
            }
            if line.hasPrefix("--- "), index + 1 < lines.count,
               lines[index + 1].hasPrefix("+++ ") {
                starts.append(index)
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("Files ") {
                starts.append(index)
            }
            index += 1
        }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
            return makeSegment(Array(lines[start..<end]))
        }
    }

    private func hunkCounts(_ header: String) -> (old: Int, new: Int)? {
        let range = NSRange(header.startIndex..<header.endIndex, in: header)
        guard let match = Self.hunkExpression.firstMatch(in: header, range: range) else {
            return nil
        }
        func integer(at capture: Int, default defaultValue: Int) -> Int {
            let captureRange = match.range(at: capture)
            guard captureRange.location != NSNotFound,
                  let swiftRange = Range(captureRange, in: header) else { return defaultValue }
            return Int(header[swiftRange]) ?? defaultValue
        }
        return (integer(at: 2, default: 1), integer(at: 4, default: 1))
    }

    private func makeSegment(_ lines: [String]) -> Segment {
        let separatorBytes = max(0, lines.count - 1)
        return Segment(
            lines: lines,
            byteCount: lines.reduce(separatorBytes) { $0 + $1.utf8.count }
        )
    }

    private func parse(_ segment: Segment) throws -> ReviewFileDiff {
        var metadata = try parseMetadata(segment.lines)
        if let renameFrom = metadata.renameFrom { metadata.oldPath = renameFrom }
        if let renameTo = metadata.renameTo { metadata.newPath = renameTo }

        guard metadata.oldPath != nil || metadata.newPath != nil else {
            throw ReviewDiffParserError.malformed("file paths are missing")
        }
        let pathIdentity = "\(metadata.oldPath ?? "/dev/null")\u{0}\(metadata.newPath ?? "/dev/null")"
        let fileID = Self.fingerprint("review-file\u{0}\(pathIdentity)")
        let fileFingerprint = Self.fingerprint(segment.lines.joined(separator: "\n"))
        let displayPath = metadata.newPath ?? metadata.oldPath ?? fileID
        let language = highlighter.language(for: displayPath)
        let change = changeKind(for: metadata)

        if segment.byteCount > limits.maximumFileBytes {
            return ReviewFileDiff(
                id: fileID,
                fingerprint: fileFingerprint,
                oldPath: metadata.oldPath,
                newPath: metadata.newPath,
                change: change,
                language: language,
                hunks: [],
                fallback: .large(
                    byteCount: segment.byteCount,
                    limit: limits.maximumFileBytes
                ),
                isUntracked: metadata.isUntracked ? true : nil
            )
        }
        guard segment.lines.count <= limits.maximumLinesPerFile else {
            return ReviewFileDiff(
                id: fileID,
                fingerprint: fileFingerprint,
                oldPath: metadata.oldPath,
                newPath: metadata.newPath,
                change: change,
                language: language,
                hunks: [],
                fallback: .omitted(reason: "file diff exceeds the line display limit"),
                isUntracked: metadata.isUntracked ? true : nil
            )
        }

        let hunks: [ReviewDiffHunk]
        do {
            hunks = try parseHunks(
                segment.lines,
                fileID: fileID,
                language: language
            )
        } catch let error as ReviewDiffParserError {
            switch error {
            case .unsafePath:
                throw error
            case .malformed, .limitExceeded:
                return ReviewFileDiff(
                    id: fileID,
                    fingerprint: fileFingerprint,
                    oldPath: metadata.oldPath,
                    newPath: metadata.newPath,
                    change: change,
                    language: language,
                    hunks: [],
                    fallback: .omitted(reason: error.localizedDescription),
                    isUntracked: metadata.isUntracked ? true : nil
                )
            }
        }

        return ReviewFileDiff(
            id: fileID,
            fingerprint: fileFingerprint,
            oldPath: metadata.oldPath,
            newPath: metadata.newPath,
            change: change,
            language: language,
            hunks: hunks,
            fallback: metadata.fallback,
            isUntracked: metadata.isUntracked ? true : nil
        )
    }

    private func parseMetadata(_ lines: [String]) throws -> Metadata {
        var result = Metadata()
        for line in lines {
            if line.hasPrefix("@@") { break }
            if line.hasPrefix("diff --git ") {
                let raw = String(line.dropFirst("diff --git ".count))
                let tokens = tokenizeGitHeader(raw)
                guard tokens.count == 2 else {
                    throw ReviewDiffParserError.malformed("invalid diff --git header")
                }
                result.oldPath = try normalizedPath(decodeGitPath(tokens[0]), stripABPrefix: true)
                result.newPath = try normalizedPath(decodeGitPath(tokens[1]), stripABPrefix: true)
            } else if line.hasPrefix("--- ") {
                let raw = String(line.dropFirst(4))
                result.oldPath = try normalizedPath(
                    decodePathHeader(raw),
                    stripABPrefix: true
                )
            } else if line.hasPrefix("+++ ") {
                let raw = String(line.dropFirst(4))
                result.newPath = try normalizedPath(
                    decodePathHeader(raw),
                    stripABPrefix: true
                )
            } else if line.hasPrefix("rename from ") {
                result.renameFrom = try normalizedPath(
                    decodePathHeader(String(line.dropFirst("rename from ".count))),
                    stripABPrefix: false
                )
                result.isRename = true
            } else if line.hasPrefix("rename to ") {
                result.renameTo = try normalizedPath(
                    decodePathHeader(String(line.dropFirst("rename to ".count))),
                    stripABPrefix: false
                )
                result.isRename = true
            } else if line.hasPrefix("similarity index ") {
                result.isRename = true
            } else if line.hasPrefix("new file mode ") {
                result.isNew = true
            } else if line.hasPrefix("deleted file mode ") {
                result.isDeleted = true
            } else if line.hasPrefix("Binary files ") {
                if result.oldPath == nil && result.newPath == nil {
                    let paths = try parseDifferPaths(line, prefix: "Binary files ")
                    result.oldPath = paths.old
                    result.newPath = paths.new
                }
                result.fallback = .binary
            } else if line == "GIT binary patch" {
                result.fallback = .binary
            } else if line.hasPrefix("LumaChat review untracked file sha256=") {
                let digest = String(line.dropFirst(
                    "LumaChat review untracked file sha256=".count
                ))
                guard digest.range(
                    of: #"^[0-9a-f]{64}$"#,
                    options: .regularExpression
                ) != nil else {
                    throw ReviewDiffParserError.malformed(
                        "invalid host untracked-file identity"
                    )
                }
                result.isUntracked = true
            } else if line.hasPrefix("LumaChat review large file ") {
                result.fallback = try largeFileFallback(in: line)
            } else if line.hasPrefix("Files ") {
                if result.oldPath == nil && result.newPath == nil {
                    let paths = try parseDifferPaths(line, prefix: "Files ")
                    result.oldPath = paths.old
                    result.newPath = paths.new
                }
                result.fallback = .omitted(reason: omittedReason(in: line))
            } else if line.contains("diff truncated at") {
                result.fallback = .omitted(reason: "diff output was truncated")
            }
        }
        return result
    }

    /// Parses only the host-generated marker used when an untracked regular
    /// file is too large to materialize as a textual diff. Git never emits
    /// this header itself; accepting one rigid decimal shape keeps arbitrary
    /// source text from becoming metadata or a mutation instruction.
    private func largeFileFallback(in line: String) throws -> ReviewDiffFallback {
        let prefix = "LumaChat review large file "
        let fields = line.dropFirst(prefix.count).split(separator: " ")
        guard fields.count == 3,
              fields[0].hasPrefix("bytes="),
              fields[1].hasPrefix("limit="),
              fields[2].hasPrefix("sha256="),
              let byteCount = Int(fields[0].dropFirst("bytes=".count)),
              let limit = Int(fields[1].dropFirst("limit=".count)),
              byteCount > limit,
              limit > 0,
              String(fields[2].dropFirst("sha256=".count)).range(
                  of: #"^[0-9a-f]{64}$"#,
                  options: .regularExpression
              ) != nil else {
            throw ReviewDiffParserError.malformed("invalid host large-file marker")
        }
        return .large(byteCount: byteCount, limit: limit)
    }

    private func parseDifferPaths(
        _ line: String,
        prefix: String
    ) throws -> (old: String?, new: String?) {
        var value = String(line.dropFirst(prefix.count))
        if value.hasSuffix(" differ") { value.removeLast(" differ".count) }
        if let range = value.range(of: " differ (") {
            value = String(value[..<range.lowerBound])
        }
        guard let separator = value.range(of: " and ") else {
            throw ReviewDiffParserError.malformed("binary/omitted file paths are invalid")
        }
        let oldRaw = String(value[..<separator.lowerBound])
        let newRaw = String(value[separator.upperBound...])
        return (
            try normalizedPath(decodePathHeader(oldRaw), stripABPrefix: true),
            try normalizedPath(decodePathHeader(newRaw), stripABPrefix: true)
        )
    }

    private func omittedReason(in line: String) -> String {
        guard let start = line.range(of: "diff omitted: ") else {
            return "text diff is unavailable"
        }
        var reason = String(line[start.upperBound...])
        while reason.last == ")" || reason.last == "." { reason.removeLast() }
        return reason.isEmpty ? "text diff is unavailable" : reason
    }

    private func changeKind(for metadata: Metadata) -> ReviewFileChangeKind {
        if metadata.isNew || metadata.oldPath == nil { return .added }
        if metadata.isDeleted || metadata.newPath == nil { return .deleted }
        if metadata.isRename || metadata.oldPath != metadata.newPath { return .renamed }
        return .modified
    }

    private func parseHunks(
        _ lines: [String],
        fileID: String,
        language: ReviewLanguage?
    ) throws -> [ReviewDiffHunk] {
        var hunks: [ReviewDiffHunk] = []
        var index = 0
        while index < lines.count {
            if Task.isCancelled { throw CancellationError() }
            let header = lines[index]
            guard header.hasPrefix("@@") else {
                index += 1
                continue
            }
            guard hunks.count < limits.maximumHunksPerFile else {
                throw ReviewDiffParserError.limitExceeded("file has too many hunks")
            }
            let range = NSRange(header.startIndex..<header.endIndex, in: header)
            guard let match = Self.hunkExpression.firstMatch(in: header, range: range) else {
                throw ReviewDiffParserError.malformed("invalid hunk header: \(header)")
            }

            func integer(at capture: Int, default defaultValue: Int) -> Int {
                let captureRange = match.range(at: capture)
                guard captureRange.location != NSNotFound,
                      let swiftRange = Range(captureRange, in: header) else { return defaultValue }
                return Int(header[swiftRange]) ?? defaultValue
            }

            let oldStart = integer(at: 1, default: 0)
            let oldCount = integer(at: 2, default: 1)
            let newStart = integer(at: 3, default: 0)
            let newCount = integer(at: 4, default: 1)
            var oldLine = oldStart
            var newLine = newStart
            var consumedOld = 0
            var consumedNew = 0
            var parsedLines: [ReviewDiffLine] = []
            index += 1

            while index < lines.count,
                  consumedOld < oldCount || consumedNew < newCount {
                if Task.isCancelled { throw CancellationError() }
                let value = lines[index]
                if value == #"\ No newline at end of file"# {
                    index += 1
                    continue
                }
                guard let marker = value.first else {
                    throw ReviewDiffParserError.malformed("empty hunk line has no marker")
                }
                let text = String(value.dropFirst())
                let syntax = highlighter.spans(in: text, language: language)
                switch marker {
                case " ":
                    parsedLines.append(ReviewDiffLine(
                        kind: .context,
                        oldLineNumber: oldLine,
                        newLineNumber: newLine,
                        text: text,
                        syntax: syntax
                    ))
                    oldLine += 1
                    newLine += 1
                    consumedOld += 1
                    consumedNew += 1
                case "-":
                    parsedLines.append(ReviewDiffLine(
                        kind: .removal,
                        oldLineNumber: oldLine,
                        newLineNumber: nil,
                        text: text,
                        syntax: syntax
                    ))
                    oldLine += 1
                    consumedOld += 1
                case "+":
                    parsedLines.append(ReviewDiffLine(
                        kind: .addition,
                        oldLineNumber: nil,
                        newLineNumber: newLine,
                        text: text,
                        syntax: syntax
                    ))
                    newLine += 1
                    consumedNew += 1
                default:
                    throw ReviewDiffParserError.malformed("unexpected hunk marker: \(marker)")
                }
                index += 1
            }
            guard consumedOld == oldCount, consumedNew == newCount else {
                throw ReviewDiffParserError.malformed("hunk line counts do not match header")
            }
            let canonicalLines = parsedLines.map { line in
                let marker = switch line.kind {
                case .context: " "
                case .addition: "+"
                case .removal: "-"
                }
                return marker + line.text
            }.joined(separator: "\n")
            let hunkFingerprint = Self.fingerprint("\(header)\n\(canonicalLines)")
            hunks.append(ReviewDiffHunk(
                id: Self.fingerprint("review-hunk\u{0}\(fileID)\u{0}\(hunkFingerprint)"),
                fingerprint: hunkFingerprint,
                header: header,
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                lines: parsedLines
            ))
        }
        return hunks
    }

    private func decodePathHeader(_ raw: String) -> String {
        var value = raw
        if !value.hasPrefix("\"") {
            value = value.split(separator: "\t", maxSplits: 1).first.map(String.init) ?? value
        }
        return decodeGitPath(value.trimmingCharacters(in: .whitespaces))
    }

    private func tokenizeGitHeader(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false
        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
            } else if character == "\\" {
                current.append(character)
                isEscaped = true
            } else if character == "\"" {
                current.append(character)
                isQuoted.toggle()
            } else if character.isWhitespace, !isQuoted {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private func decodeGitPath(_ raw: String) -> String {
        guard raw.count >= 2, raw.first == "\"", raw.last == "\"" else { return raw }
        let contents = raw.dropFirst().dropLast()
        var bytes: [UInt8] = []
        var index = contents.startIndex
        while index < contents.endIndex {
            let character = contents[index]
            if character != "\\" {
                bytes.append(contentsOf: String(character).utf8)
                index = contents.index(after: index)
                continue
            }
            index = contents.index(after: index)
            guard index < contents.endIndex else { break }
            let escaped = contents[index]
            let mapping: [Character: UInt8] = [
                "n": 0x0A, "r": 0x0D, "t": 0x09, "b": 0x08,
                "f": 0x0C, "v": 0x0B, "\\": 0x5C, "\"": 0x22
            ]
            if let byte = mapping[escaped] {
                bytes.append(byte)
                index = contents.index(after: index)
                continue
            }
            if escaped >= "0", escaped <= "7" {
                var digits = ""
                var digitIndex = index
                for _ in 0..<3 where digitIndex < contents.endIndex {
                    let digit = contents[digitIndex]
                    guard digit >= "0", digit <= "7" else { break }
                    digits.append(digit)
                    digitIndex = contents.index(after: digitIndex)
                }
                if let byte = UInt8(digits, radix: 8) {
                    bytes.append(byte)
                    index = digitIndex
                    continue
                }
            }
            bytes.append(contentsOf: String(escaped).utf8)
            index = contents.index(after: index)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func normalizedPath(_ raw: String, stripABPrefix: Bool) throws -> String? {
        if raw == "/dev/null" { return nil }
        var value = raw
        if stripABPrefix, value.hasPrefix("a/") || value.hasPrefix("b/") {
            value.removeFirst(2)
        }
        let components = NSString(string: value).pathComponents
        guard !value.isEmpty,
              value.utf8.count <= 16 * 1_024,
              !value.hasPrefix("/"),
              value != ".",
              !components.contains(".."),
              !components.contains("~"),
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ReviewDiffParserError.unsafePath(value)
        }
        return value
    }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
