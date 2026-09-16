import Foundation

struct ReviewPresentationBuilder: Sendable {
    func make(
        file: ReviewFileDiff,
        style: ReviewDiffStyle
    ) -> ReviewFilePresentation {
        let summary = ReviewFileSummary(
            path: file.displayPath,
            oldPath: file.change == .renamed ? file.oldPath : nil,
            change: file.change,
            additions: file.additionCount,
            deletions: file.deletionCount,
            hunkCount: file.hunks.count,
            fallback: file.fallback
        )
        switch style {
        case .file:
            return ReviewFilePresentation(
                style: style,
                summary: summary,
                unifiedRows: [],
                sideBySideRows: []
            )
        case .unified:
            return ReviewFilePresentation(
                style: style,
                summary: summary,
                unifiedRows: unifiedRows(for: file),
                sideBySideRows: []
            )
        case .sideBySide:
            return ReviewFilePresentation(
                style: style,
                summary: summary,
                unifiedRows: [],
                sideBySideRows: sideBySideRows(for: file)
            )
        }
    }

    func summary(for file: ReviewFileDiff) -> ReviewFileSummary {
        make(file: file, style: .file).summary
    }

    private func unifiedRows(for file: ReviewFileDiff) -> [ReviewUnifiedRow] {
        var rows: [ReviewUnifiedRow] = []
        for hunk in file.hunks {
            rows.append(ReviewUnifiedRow(
                kind: .hunkHeader,
                hunkID: hunk.id,
                oldLineNumber: nil,
                newLineNumber: nil,
                text: hunk.header,
                syntax: []
            ))
            rows.append(contentsOf: hunk.lines.map { line in
                ReviewUnifiedRow(
                    kind: unifiedKind(for: line.kind),
                    hunkID: hunk.id,
                    oldLineNumber: line.oldLineNumber,
                    newLineNumber: line.newLineNumber,
                    text: line.text,
                    syntax: line.syntax
                )
            })
        }
        return rows
    }

    private func unifiedKind(for kind: ReviewDiffLineKind) -> ReviewUnifiedRow.Kind {
        switch kind {
        case .context: .context
        case .addition: .addition
        case .removal: .removal
        }
    }

    private func sideBySideRows(for file: ReviewFileDiff) -> [ReviewSideBySideRow] {
        var rows: [ReviewSideBySideRow] = []
        for hunk in file.hunks {
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                if line.kind == .context {
                    rows.append(ReviewSideBySideRow(
                        hunkID: hunk.id,
                        left: cell(from: line, side: .old),
                        right: cell(from: line, side: .new)
                    ))
                    index += 1
                    continue
                }

                var removals: [ReviewDiffLine] = []
                var additions: [ReviewDiffLine] = []
                while index < hunk.lines.count, hunk.lines[index].kind != .context {
                    let changedLine = hunk.lines[index]
                    if changedLine.kind == .removal {
                        removals.append(changedLine)
                    } else {
                        additions.append(changedLine)
                    }
                    index += 1
                }
                let rowCount = max(removals.count, additions.count)
                for offset in 0..<rowCount {
                    rows.append(ReviewSideBySideRow(
                        hunkID: hunk.id,
                        left: offset < removals.count
                            ? cell(from: removals[offset], side: .old)
                            : nil,
                        right: offset < additions.count
                            ? cell(from: additions[offset], side: .new)
                            : nil
                    ))
                }
            }
        }
        return rows
    }

    private func cell(
        from line: ReviewDiffLine,
        side: ReviewLineSide
    ) -> ReviewDiffCell? {
        let lineNumber = side == .old ? line.oldLineNumber : line.newLineNumber
        guard let lineNumber else { return nil }
        return ReviewDiffCell(
            lineNumber: lineNumber,
            text: line.text,
            kind: line.kind,
            syntax: line.syntax
        )
    }
}
