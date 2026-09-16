import Foundation
import XCTest
@testable import LumaChat

final class AgentComposerSupportTests: XCTestCase {
    func testWorkspaceFileReferencesStayRelativeAndInsideSelectedWorkspace() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        let workspace = AgentWorkspace(
            name: root.lastPathComponent,
            rootPath: root.path,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )

        let references = try AgentComposerSupport.validatedWorkspaceFileReferences(
            [root.appendingPathComponent("Package.swift"), root.appendingPathComponent("Package.swift")],
            workspace: workspace
        )

        XCTAssertEqual(references, ["Package.swift"])
        XCTAssertThrowsError(
            try AgentComposerSupport.validatedWorkspaceFileReferences(
                [URL(fileURLWithPath: "/etc/hosts")],
                workspace: workspace
            )
        ) { error in
            guard case WorkspaceSecurityError.pathEscapesWorkspace = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorkspaceFileBlockJSONQuotesPathsAndAppendsWithoutAbsolutePath() {
        let block = AgentComposerSupport.workspaceFileReferenceBlock([
            "Sources/ordinary.swift",
            "Sources/quote\"and-newline\n.swift"
        ])
        let combined = AgentComposerSupport.appending(block, to: "Review these files")

        XCTAssertTrue(combined.hasPrefix("Review these files\n\n[Attached workspace files]"))
        XCTAssertTrue(combined.contains(#""Sources/ordinary.swift""#))
        XCTAssertTrue(combined.contains(#"quote\"and-newline\n.swift"#))
        XCTAssertFalse(combined.contains(FileManager.default.currentDirectoryPath))
    }

    func testWorkspaceFileReferenceLimitIsEnforcedBeforePathResolution() {
        let workspace = AgentWorkspace(
            name: "Fixture",
            rootPath: FileManager.default.currentDirectoryPath,
            allowedPaths: [],
            bookmarkData: nil,
            gitRepository: false,
            branch: nil
        )
        let urls = (0...AgentComposerSupport.maximumWorkspaceFileReferences).map {
            URL(fileURLWithPath: "/does-not-matter-\($0)")
        }

        XCTAssertThrowsError(
            try AgentComposerSupport.validatedWorkspaceFileReferences(urls, workspace: workspace)
        ) { error in
            XCTAssertEqual(
                error as? AgentComposerError,
                .tooManyFiles(AgentComposerSupport.maximumWorkspaceFileReferences)
            )
        }
    }

    func testOnlyConnectedMCPChoicesAreOffered() {
        let connectedID = UUID()
        let disconnectedID = UUID()
        let resource = MCPResourceDescriptor(
            uri: "docs://readme",
            name: "README",
            title: nil,
            description: nil,
            mimeType: "text/plain",
            size: nil
        )
        let prompt = MCPPromptDescriptor(
            name: "review",
            title: nil,
            description: nil,
            arguments: nil
        )
        let connected = MCPServerSnapshot(
            configuration: MCPServerConfiguration(
                id: connectedID,
                name: "Connected",
                transport: .stdio(.init(command: "/usr/bin/true"))
            ),
            state: .connected,
            negotiatedProtocolVersion: nil,
            serverInfo: nil,
            tools: [],
            resources: [resource],
            prompts: [prompt],
            lastError: nil
        )
        let disconnected = MCPServerSnapshot(
            configuration: MCPServerConfiguration(
                id: disconnectedID,
                name: "Disconnected",
                transport: .stdio(.init(command: "/usr/bin/true"))
            ),
            state: .disconnected,
            negotiatedProtocolVersion: nil,
            serverInfo: nil,
            tools: [],
            resources: [resource],
            prompts: [prompt],
            lastError: nil
        )

        XCTAssertEqual(
            AgentComposerSupport.resourceChoices(from: [disconnected, connected]).map(\.serverID),
            [connectedID]
        )
        XCTAssertEqual(
            AgentComposerSupport.promptChoices(from: [disconnected, connected]).map(\.serverID),
            [connectedID]
        )
    }

    func testResourceRendererIncludesTextButNeverBinaryBytes() throws {
        let descriptor = MCPResourceDescriptor(
            uri: "docs://readme",
            name: "README",
            title: "Project README",
            description: nil,
            mimeType: "text/markdown",
            size: nil
        )
        let choice = AgentMCPResourceChoice(
            serverID: UUID(),
            serverName: "Docs",
            resource: descriptor
        )
        let result = MCPResourceReadResult(contents: [
            .text(.init(uri: descriptor.uri, mimeType: "text/markdown", text: "Hello context", metadata: nil)),
            .blob(.init(uri: "docs://image", mimeType: "image/png", data: Data([0, 1, 2, 3]), metadata: nil))
        ])

        let rendered = try AgentComposerSupport.resourceContextBlock(choice: choice, result: result)

        XCTAssertTrue(rendered.contains("Hello context"))
        XCTAssertTrue(rendered.contains("Binary resource omitted from Composer: 4 bytes"))
        XCTAssertFalse(rendered.contains(Data([0, 1, 2, 3]).base64EncodedString()))
    }

    func testPromptArgumentsRequireAdvertisedRequiredValuesAndIgnoreStaleFields() throws {
        let prompt = MCPPromptDescriptor(
            name: "review",
            title: nil,
            description: nil,
            arguments: [
                .init(name: "focus", title: nil, description: nil, required: true),
                .init(name: "tone", title: nil, description: nil, required: false)
            ]
        )

        XCTAssertThrowsError(
            try AgentComposerSupport.normalizedPromptArguments([:], for: prompt)
        ) { error in
            XCTAssertEqual(error as? AgentComposerError, .missingPromptArgument("focus"))
        }
        XCTAssertEqual(
            try AgentComposerSupport.normalizedPromptArguments(
                ["focus": " concurrency ", "stale": "must not cross MCP seam"],
                for: prompt
            ),
            ["focus": "concurrency"]
        )
    }

    func testPromptRendererPreservesRolesAndOmitsBinaryPayloads() throws {
        let descriptor = MCPPromptDescriptor(
            name: "review",
            title: "Code Review",
            description: nil,
            arguments: nil
        )
        let choice = AgentMCPPromptChoice(
            serverID: UUID(),
            serverName: "Review Server",
            prompt: descriptor
        )
        let result = MCPPromptGetResult(
            description: "Review selected code",
            messages: [
                .init(role: .user, content: .text(.init(text: "Find races", annotations: nil, metadata: nil))),
                .init(
                    role: .assistant,
                    content: .image(.init(data: Data([4, 5, 6]), mimeType: "image/png", annotations: nil, metadata: nil))
                )
            ]
        )

        let rendered = try AgentComposerSupport.promptBlock(choice: choice, result: result)

        XCTAssertTrue(rendered.contains("[USER]\nFind races"))
        XCTAssertTrue(rendered.contains("[ASSISTANT]\n[MCP prompt image omitted from Composer"))
        XCTAssertFalse(rendered.contains(Data([4, 5, 6]).base64EncodedString()))
    }
}
