import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class LocalLiveContextTests: XCTestCase {
    func testLiveSnapshotCreatesRequestOnlyInMemoryAttachment() {
        let connection = LocalAppConnection(
            source: .visualStudioCode,
            processIdentifier: 42,
            bundleIdentifier: "com.microsoft.VSCode",
            applicationName: "Visual Studio Code"
        )
        let snapshot = LocalDocumentSnapshot(
            connection: connection,
            identity: LocalDocumentIdentity(
                processIdentifier: 42,
                bundleIdentifier: "com.microsoft.VSCode",
                identifier: "/tmp/Live.swift",
                isStable: true
            ),
            documentTitle: "Live.swift",
            text: "let version = 2",
            contentDigest: "digest",
            capturedAt: Date(timeIntervalSince1970: 1)
        )

        let prepared = snapshot.requestAttachment
        XCTAssertNil(prepared.data)
        XCTAssertNil(prepared.attachment.relativePath)
        XCTAssertEqual(prepared.attachment.extractedText, "let version = 2")
        XCTAssertEqual(prepared.attachment.kind, .capturedContext)
        XCTAssertTrue(prepared.attachment.name.contains("Live.swift"))
    }

    func testOnlyAllowListedEditorsSupportLiveDocumentAccess() {
        XCTAssertTrue(LocalContextSource.notes.supportsLiveDocumentAccess)
        XCTAssertTrue(LocalContextSource.textEdit.supportsLiveDocumentAccess)
        XCTAssertTrue(LocalContextSource.visualStudioCode.supportsLiveDocumentAccess)
        XCTAssertTrue(LocalContextSource.xcode.supportsLiveDocumentAccess)
        XCTAssertFalse(LocalContextSource.currentSelection.supportsLiveDocumentAccess)
        XCTAssertFalse(LocalContextSource.terminal.supportsLiveDocumentAccess)
    }

    func testUnsupportedSourceIsRejectedBeforeAttemptingAccessibilityRead() {
        let service = LocalContextService(observeWorkspaceActivations: false)
        XCTAssertThrowsError(try service.connect(to: .terminal)) { error in
            guard case LocalContextError.liveDocumentAccessUnsupported = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCompleteRequestAttachmentIsEligibleForGuardedWrite() {
        let attachment = ChatAttachment(
            name: "Live.swift · 即時文件",
            relativePath: nil,
            mimeType: "text/plain; charset=utf-8",
            kind: .capturedContext,
            byteCount: 21,
            extractedText: "let currentVersion = 2",
            sourceLabel: "Visual Studio Code · 即時文件"
        )
        let request = ChatMessage(
            role: .user,
            content: "更新版本",
            attachments: [attachment]
        )

        XCTAssertTrue(
            ChatViewModel.requestContainsCompleteAttachment(attachment, in: [request])
        )
    }

    func testTruncatedRequestAttachmentIsNotEligibleForGuardedWrite() {
        let attachment = ChatAttachment(
            name: "Live.swift · 即時文件",
            relativePath: nil,
            mimeType: "text/plain; charset=utf-8",
            kind: .capturedContext,
            byteCount: 21,
            extractedText: "let currentVersion = 2",
            sourceLabel: "Visual Studio Code · 即時文件"
        )
        var truncated = attachment
        truncated.extractedText = "let current"
        let request = ChatMessage(
            role: .user,
            content: "更新版本",
            attachments: [truncated]
        )

        XCTAssertFalse(
            ChatViewModel.requestContainsCompleteAttachment(attachment, in: [request])
        )
    }
}
