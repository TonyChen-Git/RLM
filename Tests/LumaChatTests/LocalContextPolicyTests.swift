import XCTest
@testable import LumaChat

@MainActor
final class LocalContextPolicyTests: XCTestCase {
    func testLiveReadAndWholeDocumentWriteAllowListsAreDistinct() {
        XCTAssertTrue(LocalContextSource.notes.supportsLiveDocumentAccess)
        XCTAssertFalse(LocalContextSource.notes.supportsGuardedDocumentWrite)

        for source in [
            LocalContextSource.textEdit,
            .visualStudioCode,
            .xcode
        ] {
            XCTAssertTrue(source.supportsLiveDocumentAccess)
            XCTAssertTrue(source.supportsGuardedDocumentWrite)
        }

        for source in [
            LocalContextSource.currentSelection,
            .terminal
        ] {
            XCTAssertFalse(source.supportsLiveDocumentAccess)
            XCTAssertFalse(source.supportsGuardedDocumentWrite)
        }

        XCTAssertTrue(LocalContextSource.visualStudioCode.requiresLosslessClipboardDocumentRead)
        XCTAssertTrue(LocalContextSource.xcode.requiresLosslessClipboardDocumentRead)
        XCTAssertFalse(LocalContextSource.textEdit.requiresLosslessClipboardDocumentRead)
        XCTAssertFalse(LocalContextSource.notes.requiresLosslessClipboardDocumentRead)
    }

    func testNotesWholeDocumentReplacementIsRejectedBeforeAppAccess() async {
        let service = LocalContextService(observeWorkspaceActivations: false)
        let connection = LocalAppConnection(
            source: .notes,
            processIdentifier: 1,
            bundleIdentifier: "com.apple.Notes",
            applicationName: "備忘錄"
        )

        do {
            try await service.replaceCurrentDocument(
                with: "replacement",
                using: connection
            )
            XCTFail("Notes whole-document replacement must be rejected")
        } catch LocalContextError.wholeDocumentWriteUnsupported(let application) {
            XCTAssertEqual(application, "備忘錄")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
