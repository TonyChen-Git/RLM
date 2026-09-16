import Foundation
import XCTest
@testable import LumaChat

@MainActor
final class MCPResourcesPromptsTests: XCTestCase {
    func testStdioTemplatesPaginationAndTypedResourcePromptResults() async throws {
        let client = makeClient(script: Self.integrationServerScript)
        _ = try await client.connect()
        do {
            let templates = try await client.listResourceTemplates()
            XCTAssertEqual(templates.map(\.name), ["Project File", "Issue"])
            XCTAssertEqual(templates.map(\.uriTemplate), ["file:///{path}", "issue:///{id}"])
            XCTAssertEqual(templates[1].metadata?["page"]?.intValue, 2)

            let resource = try await client.readResource(uri: "file:///fixture")
            XCTAssertEqual(resource.contents.count, 2)
            guard case .text(let text) = resource.contents[0] else {
                return XCTFail("Expected typed text resource content")
            }
            XCTAssertEqual(text.uri, "file:///fixture")
            XCTAssertEqual(text.text, "fixture text")
            guard case .blob(let blob) = resource.contents[1] else {
                return XCTFail("Expected typed blob resource content")
            }
            XCTAssertEqual(blob.data, Data([1, 2, 3]))

            let prompt = try await client.getPrompt(
                name: "review",
                arguments: ["tone": "brief"]
            )
            XCTAssertEqual(prompt.description, "Review the selected context")
            XCTAssertEqual(prompt.messages.count, 6)
            XCTAssertEqual(prompt.messages.map(\.role), [.user, .assistant, .user, .assistant, .user, .assistant])

            guard case .text(let promptText) = prompt.messages[0].content else {
                return XCTFail("Expected text prompt content")
            }
            XCTAssertEqual(promptText.text, "Review briefly")
            XCTAssertEqual(promptText.annotations?.priority, 0.5)

            guard case .image(let image) = prompt.messages[1].content else {
                return XCTFail("Expected image prompt content")
            }
            XCTAssertEqual(image.data, Data([1, 2, 3]))
            XCTAssertEqual(image.mimeType, "image/png")

            guard case .audio(let audio) = prompt.messages[2].content else {
                return XCTFail("Expected audio prompt content")
            }
            XCTAssertEqual(audio.data, Data([4, 5]))

            guard case .resourceLink(let link) = prompt.messages[3].content else {
                return XCTFail("Expected resource-link prompt content")
            }
            XCTAssertEqual(link.uri, "file:///linked")
            XCTAssertEqual(link.size, 42)

            guard case .resource(let embedded) = prompt.messages[4].content,
                  case .text(let embeddedText) = embedded.resource else {
                return XCTFail("Expected embedded text resource prompt content")
            }
            XCTAssertEqual(embeddedText.text, "embedded")

            guard case .unknown(let type, let value) = prompt.messages[5].content else {
                return XCTFail("Expected bounded forward-compatible prompt content")
            }
            XCTAssertEqual(type, "future_block")
            XCTAssertEqual(value["payload"]?["value"]?.stringValue, "kept")
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    func testStdioRejectsMalformedBase64OversizeAndArgumentFloods() async throws {
        let client = makeClient(script: Self.integrationServerScript)
        _ = try await client.connect()

        await expectInvalidResponse {
            _ = try await client.readResource(uri: "file:///malformed")
        }
        await expectInvalidResponse {
            _ = try await client.getPrompt(name: "bad-binary")
        }

        let tooManyArguments = Dictionary(
            uniqueKeysWithValues: (0..<129).map { ("argument-\($0)", "value") }
        )
        do {
            _ = try await client.getPrompt(name: "review", arguments: tooManyArguments)
            XCTFail("Expected an input argument-count failure")
        } catch let error as MCPError {
            guard case .invalidConfiguration = error else {
                await client.disconnect()
                return XCTFail("Expected invalidConfiguration, received \(error)")
            }
        }
        await expectInvalidResponse {
            _ = try await client.getPrompt(name: "oversize-unknown")
        }
        await expectInvalidResponse {
            _ = try await client.readResource(uri: "file:///oversize")
        }
        await client.disconnect()
    }

    func testUnadvertisedOptionalCapabilitiesFailWithoutWireProbe() async throws {
        let client = makeClient(script: Self.noOptionalCapabilitiesServerScript)
        _ = try await client.connect()
        do {
            _ = try await client.listResources()
            XCTFail("Expected resources capability failure")
        } catch let error as MCPError {
            guard case .remote(let code, _) = error else {
                await client.disconnect()
                return XCTFail("Expected method-not-found error, received \(error)")
            }
            XCTAssertEqual(code, -32601)
        }
        do {
            _ = try await client.getPrompt(name: "anything")
            XCTFail("Expected prompts capability failure")
        } catch let error as MCPError {
            guard case .remote(let code, _) = error else {
                await client.disconnect()
                return XCTFail("Expected method-not-found error, received \(error)")
            }
            XCTAssertEqual(code, -32601)
        }
        await client.disconnect()
    }

    func testManagerSnapshotDiscoversTemplatesAndRedactsPromptErrors() async throws {
        let registry = ToolRegistry()
        let manager = MCPManager(registry: registry)
        let configuration = MCPServerConfiguration(
            name: "STDIO resources and prompts",
            permissionLevel: .read,
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/python3",
                    arguments: ["-u", "-c", Self.integrationServerScript],
                    environment: ["PYTHONDONTWRITEBYTECODE": "1"]
                )
            )
        )

        let snapshot = try await manager.connect(configuration)
        XCTAssertEqual(snapshot.resourceTemplates.map(\.name), ["Project File", "Issue"])
        do {
            _ = try await manager.getPrompt(serverID: configuration.id, name: "remote-error")
            XCTFail("Expected remote prompt error")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("secret-token-value"))
            XCTAssertTrue(error.localizedDescription.contains("[REDACTED]"))
        }

        let refreshed = await manager.snapshot(serverID: configuration.id)
        let logs = refreshed?.logs ?? []
        XCTAssertFalse(logs.map(\.message).joined().contains("secret-token-value"))
        XCTAssertTrue(logs.map(\.message).joined().contains("[REDACTED]"))
        await manager.disconnect(serverID: configuration.id)
    }

    private func makeClient(script: String) -> MCPClient {
        let configuration = MCPServerConfiguration(
            name: "STDIO fixture",
            permissionLevel: .read,
            transport: .stdio(
                MCPStdioConfiguration(
                    command: "/usr/bin/python3",
                    arguments: ["-u", "-c", script],
                    environment: ["PYTHONDONTWRITEBYTECODE": "1"]
                )
            )
        )
        return MCPClient(
            configuration: configuration,
            transport: MCPStdioTransport(
                serverID: configuration.id,
                configuration: {
                    guard case .stdio(let stdio) = configuration.transport else {
                        preconditionFailure("Expected STDIO configuration")
                    }
                    return stdio
                }(),
                allowsNetwork: false
            ),
            requestTimeout: 10
        )
    }

    private func expectInvalidResponse(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected invalid MCP response", file: file, line: line)
        } catch let error as MCPError {
            guard case .invalidResponse = error else {
                return XCTFail("Expected invalidResponse, received \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected MCPError, received \(error)", file: file, line: line)
        }
    }

    private static let integrationServerScript = #"""
    import json
    import sys
    import time

    def success(ident, result):
        return {"jsonrpc": "2.0", "id": ident, "result": result}

    def failure(ident, code, message):
        return {"jsonrpc": "2.0", "id": ident, "error": {"code": code, "message": message}}

    for line in sys.stdin:
        request = json.loads(line)
        ident = request.get("id")
        if ident is None:
            continue
        method = request.get("method")
        params = request.get("params") or {}
        if method == "initialize":
            response = success(ident, {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                "serverInfo": {"name": "stdio-fixture", "version": "1.0"}
            })
        elif method == "tools/list":
            response = success(ident, {"tools": []})
        elif method == "resources/list":
            response = success(ident, {"resources": [{
                "uri": "file:///fixture", "name": "Fixture", "mimeType": "text/plain"
            }]})
        elif method == "resources/templates/list":
            if params.get("cursor") == "page-2":
                response = success(ident, {"resourceTemplates": [{
                    "uriTemplate": "issue:///{id}",
                    "name": "Issue",
                    "annotations": {"audience": ["user"], "priority": 0.7},
                    "_meta": {"page": 2}
                }]})
            else:
                response = success(ident, {
                    "resourceTemplates": [{
                        "uriTemplate": "file:///{path}",
                        "name": "Project File",
                        "description": "A project file"
                    }],
                    "nextCursor": "page-2"
                })
        elif method == "prompts/list":
            response = success(ident, {"prompts": [{
                "name": "review",
                "arguments": [{"name": "tone", "title": "Tone", "required": False}]
            }]})
        elif method == "resources/read":
            uri = params.get("uri")
            if uri == "file:///malformed":
                contents = [{"uri": uri, "text": "ambiguous", "blob": "AQID"}]
            elif uri == "file:///oversize":
                contents = [{"uri": uri, "text": "x" * (4 * 1024 * 1024 + 1)}]
            else:
                contents = [
                    {"uri": uri, "mimeType": "text/plain", "text": "fixture text"},
                    {"uri": "bytes:///fixture", "mimeType": "application/octet-stream", "blob": "AQID"}
                ]
            response = success(ident, {"contents": contents})
        elif method == "prompts/get":
            name = params.get("name")
            if name == "remote-error":
                response = failure(ident, -32001, "Authorization: Bearer secret-token-value")
            elif name == "bad-binary":
                response = success(ident, {"messages": [{
                    "role": "user",
                    "content": {"type": "image", "mimeType": "image/png", "data": "not base64"}
                }]})
            elif name == "oversize-unknown":
                response = success(ident, {"messages": [{
                    "role": "user",
                    "content": {"type": "future_block", "payload": "x" * (1024 * 1024 + 1)}
                }]})
            elif params.get("arguments") != {"tone": "brief"}:
                response = failure(ident, -32602, "Expected bounded string arguments")
            else:
                response = success(ident, {
                    "description": "Review the selected context",
                    "messages": [
                        {"role": "user", "content": {
                            "type": "text", "text": "Review briefly",
                            "annotations": {"audience": ["user"], "priority": 0.5},
                            "_meta": {"safe": True}
                        }},
                        {"role": "assistant", "content": {
                            "type": "image", "mimeType": "image/png", "data": "AQID"
                        }},
                        {"role": "user", "content": {
                            "type": "audio", "mimeType": "audio/wav", "data": "BAU="
                        }},
                        {"role": "assistant", "content": {
                            "type": "resource_link", "uri": "file:///linked", "name": "Linked",
                            "title": "Linked file", "mimeType": "text/plain", "size": 42
                        }},
                        {"role": "user", "content": {
                            "type": "resource", "resource": {
                                "uri": "file:///embedded", "mimeType": "text/plain", "text": "embedded"
                            }
                        }},
                        {"role": "assistant", "content": {
                            "type": "future_block", "payload": {"value": "kept"}
                        }}
                    ]
                })
        else:
            response = failure(ident, -32601, "Method not found")
        encoded = json.dumps(response, separators=(",", ":"))
        streams_large_response = (
            method == "resources/read" and params.get("uri") == "file:///oversize"
        ) or (
            method == "prompts/get" and params.get("name") == "oversize-unknown"
        )
        if streams_large_response:
            for offset in range(0, len(encoded), 16384):
                sys.stdout.write(encoded[offset:offset + 16384])
                sys.stdout.flush()
                time.sleep(0.01)
            sys.stdout.write("\n")
            sys.stdout.flush()
        else:
            print(encoded, flush=True)
    """#

    private static let noOptionalCapabilitiesServerScript = #"""
    import json
    import sys

    for line in sys.stdin:
        request = json.loads(line)
        ident = request.get("id")
        if ident is None:
            continue
        if request.get("method") == "initialize":
            response = {
                "jsonrpc": "2.0", "id": ident,
                "result": {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "no-optionals", "version": "1.0"}
                }
            }
        else:
            response = {
                "jsonrpc": "2.0", "id": ident,
                "error": {"code": -32099, "message": "Unexpected wire probe"}
            }
        print(json.dumps(response, separators=(",", ":")), flush=True)
    """#
}
