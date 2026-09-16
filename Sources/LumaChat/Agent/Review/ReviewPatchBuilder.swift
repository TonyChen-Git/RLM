import Foundation

enum ReviewPatchDirection: String, Codable, Equatable, Sendable {
    case forward
    case reverse
}

/// All identity observed by the UI when it offered a mutation. The service
/// compares both fingerprints against its latest parsed snapshot before it
/// emits a patch; the Git layer must still run its own apply/check operation.
struct ReviewPatchSelection: Codable, Equatable, Sendable {
    var fileID: String
    var fileFingerprint: String
    var hunkID: String?
    var hunkFingerprint: String?
}

struct ReviewPatchPayload: Codable, Equatable, Sendable {
    var selection: ReviewPatchSelection
    var direction: ReviewPatchDirection
    var unifiedDiff: String
}

enum ReviewPatchError: LocalizedError, Equatable, Sendable {
    case staleFile
    case hunkNotFound(String)
    case staleHunk
    case unavailable(ReviewDiffFallback)
    case noTextualPatch

    var errorDescription: String? {
        switch self {
        case .staleFile:
            "The file diff changed after it was displayed. Refresh Review before applying it."
        case .hunkNotFound(let id):
            "The selected Review hunk no longer exists: \(id)"
        case .staleHunk:
            "The hunk changed after it was displayed. Refresh Review before applying it."
        case .unavailable:
            "A textual patch is unavailable for this file."
        case .noTextualPatch:
            "The selected file has no textual or rename patch to apply."
        }
    }
}

struct ReviewPatchBuilder: Sendable {
    func make(
        file: ReviewFileDiff,
        expectedFileFingerprint: String,
        hunkID: String? = nil,
        expectedHunkFingerprint: String? = nil,
        direction: ReviewPatchDirection
    ) throws -> ReviewPatchPayload {
        guard file.fingerprint == expectedFileFingerprint else {
            throw ReviewPatchError.staleFile
        }
        if let fallback = file.fallback {
            throw ReviewPatchError.unavailable(fallback)
        }

        let selectedHunks: [ReviewDiffHunk]
        let selectedHunk: ReviewDiffHunk?
        if let hunkID {
            guard let hunk = file.hunks.first(where: { $0.id == hunkID }) else {
                throw ReviewPatchError.hunkNotFound(hunkID)
            }
            guard let expectedHunkFingerprint,
                  hunk.fingerprint == expectedHunkFingerprint else {
                throw ReviewPatchError.staleHunk
            }
            selectedHunks = [hunk]
            selectedHunk = hunk
        } else {
            guard expectedHunkFingerprint == nil else {
                throw ReviewPatchError.staleHunk
            }
            selectedHunks = file.hunks
            selectedHunk = nil
        }
        guard !selectedHunks.isEmpty || file.change == .renamed else {
            throw ReviewPatchError.noTextualPatch
        }

        let oldPath = direction == .forward ? file.oldPath : file.newPath
        let newPath = direction == .forward ? file.newPath : file.oldPath
        let gitOldPath = oldPath ?? newPath
        let gitNewPath = newPath ?? oldPath
        guard let gitOldPath, let gitNewPath else {
            throw ReviewPatchError.noTextualPatch
        }

        var output = "diff --git \(gitToken("a/\(gitOldPath)")) \(gitToken("b/\(gitNewPath)"))\n"
        if file.change == .renamed,
           let renameFrom = oldPath,
           let renameTo = newPath {
            if selectedHunks.isEmpty { output += "similarity index 100%\n" }
            output += "rename from \(pathHeader(renameFrom))\n"
            output += "rename to \(pathHeader(renameTo))\n"
        }
        if !selectedHunks.isEmpty {
            output += "--- \(oldPath.map { pathHeader("a/\($0)") } ?? "/dev/null")\n"
            output += "+++ \(newPath.map { pathHeader("b/\($0)") } ?? "/dev/null")\n"
            for hunk in selectedHunks {
                output += rendered(hunk: hunk, direction: direction)
            }
        }

        return ReviewPatchPayload(
            selection: ReviewPatchSelection(
                fileID: file.id,
                fileFingerprint: file.fingerprint,
                hunkID: selectedHunk?.id,
                hunkFingerprint: selectedHunk?.fingerprint
            ),
            direction: direction,
            unifiedDiff: output
        )
    }

    private func rendered(
        hunk: ReviewDiffHunk,
        direction: ReviewPatchDirection
    ) -> String {
        let oldStart = direction == .forward ? hunk.oldStart : hunk.newStart
        let oldCount = direction == .forward ? hunk.oldCount : hunk.newCount
        let newStart = direction == .forward ? hunk.newStart : hunk.oldStart
        let newCount = direction == .forward ? hunk.newCount : hunk.oldCount
        var output = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\(headerSuffix(hunk.header))\n"
        for line in hunk.lines {
            let marker: Character = switch (direction, line.kind) {
            case (_, .context): " "
            case (.forward, .addition), (.reverse, .removal): "+"
            case (.forward, .removal), (.reverse, .addition): "-"
            }
            output.append(marker)
            output += line.text
            output.append("\n")
        }
        return output
    }

    private func headerSuffix(_ header: String) -> String {
        let remainder = header.dropFirst(min(2, header.count))
        guard let closing = remainder.range(of: "@@") else { return "" }
        return String(remainder[closing.upperBound...])
    }

    private func pathHeader(_ path: String) -> String {
        gitToken(path)
    }

    private func gitToken(_ value: String) -> String {
        let needsQuotes = value.contains { character in
            character.isWhitespace || character == "\\" || character == "\""
        }
        guard needsQuotes else { return value }
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\t": escaped += "\\t"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
