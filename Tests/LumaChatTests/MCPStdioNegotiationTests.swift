import Foundation
import XCTest
@testable import LumaChat

final class MCPStdioNegotiationTests: XCTestCase {
    func testMalformedOrUncorrelatedProbeErrorsFailBeforeFallback() async throws {
        let responses = [
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32021,"message":"Missing capability"}}"#,
            #"{"jsonrpc":"2.0","id":999,"error":{"code":-32021,"message":"Missing capability"}}"#,
            #"{"jsonrpc":"2.0","error":{"code":"invalid","message":"Malformed"}}"#
        ]
        for response in responses {
            let script = "while IFS= read -r request; do printf '%s\\n' '\(response)'; done"
            let stdio = MCPStdioConfiguration(command: "/bin/zsh", arguments: ["-c", script])
            let config = MCPServerConfiguration(name: "Malformed probe", protocolMode: .automatic, transport: .stdio(stdio))
            let client = MCPClient(configuration: config, transport: MCPStdioTransport(
                serverID: config.id, configuration: stdio, allowsNetwork: false
            ), requestTimeout: 2)
            do {
                _ = try await client.connect()
                XCTFail("Malformed or uncorrelated probe error must fail closed")
            } catch let error as MCPError {
                guard case .invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
            await client.disconnect()
        }
    }

    func testIdlessModernCapabilityErrorDoesNotTimeOutIntoLegacyFallback() async throws {
        let script = #"""
        while IFS= read -r request; do
            if [[ "$request" == *'"method":"server/discover"'* ]]; then
                printf '{"jsonrpc":"2.0","error":{"code":-32021,"message":"Missing capability"}}\n'
            else
                exit 14
            fi
        done
        """#
        let stdio = MCPStdioConfiguration(command: "/bin/zsh", arguments: ["-c", script])
        let config = MCPServerConfiguration(name: "Capability error", protocolMode: .automatic, transport: .stdio(stdio))
        let client = MCPClient(configuration: config, transport: MCPStdioTransport(
            serverID: config.id, configuration: stdio, allowsNetwork: false
        ), requestTimeout: 2)
        do {
            _ = try await client.connect()
            XCTFail("A recognized modern error must not select legacy or grant capabilities")
        } catch let error as MCPError {
            guard case .remote(let code, _) = error else {
                return XCTFail("Expected the original capability error, got \(error)")
            }
            XCTAssertEqual(code, -32021)
        }
        await client.disconnect()
    }

    func testRealStdioProbeTimeoutRestartsCleanlyAndLegacyRemainsUsable() async throws {
        // The legacy fixture deliberately ignores discover. Cancellation kills
        // its process group; a late teardown must not kill the replacement.
        let script = #"""
        while IFS= read -r request; do
            if [[ "$request" == *'"method":"server/discover"'* ]]; then continue; fi
            if [[ "$request" =~ '"id":([0-9]+)' ]]; then id=$match[1]; else continue; fi
            if [[ "$request" == *'"method":"initialize"'* ]]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"Legacy fixture","version":"1"}}}\n' "$id"
            else
                printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[]}}\n' "$id"
            fi
        done
        """#
        let stdio = MCPStdioConfiguration(command: "/bin/zsh", arguments: ["-c", script])
        let config = MCPServerConfiguration(name: "Legacy probe", protocolMode: .automatic, transport: .stdio(stdio))
        let transport = MCPStdioTransport(serverID: config.id, configuration: stdio, allowsNetwork: false)
        let client = MCPClient(configuration: config, transport: transport, requestTimeout: 1)
        do {
            for _ in 0..<3 {
                let connected = try await client.connect()
                XCTAssertEqual(connected.protocolVersion, MCPClient.protocolVersion)
                let tools = try await client.listTools()
                XCTAssertTrue(tools.isEmpty)
                await client.disconnect()
            }
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func testRealStatelessStdioNeverInitializesAndCarriesMetadata() async throws {
        let script = #"""
        while IFS= read -r request; do
            if [[ "$request" =~ '"id":([0-9]+)' ]]; then id=$match[1]; else exit 11; fi
            if [[ "$request" != *'io.modelcontextprotocol/protocolVersion'* || "$request" != *'2026-07-28'* ]]; then exit 12; fi
            if [[ "$request" == *'"method":"server/discover"'* ]]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}}}}\n' "$id"
            elif [[ "$request" == *'"method":"tools/list"'* ]]; then
                printf '{"jsonrpc":"2.0","id":%s,"result":{"resultType":"complete","tools":[]}}\n' "$id"
            else
                exit 13
            fi
        done
        """#
        let stdio = MCPStdioConfiguration(command: "/bin/zsh", arguments: ["-c", script])
        let config = MCPServerConfiguration(name: "Stateless process", protocolMode: .stateless, transport: .stdio(stdio))
        let client = MCPClient(configuration: config, transport: MCPStdioTransport(
            serverID: config.id, configuration: stdio, allowsNetwork: false
        ), requestTimeout: 5)
        do {
            let connected = try await client.connect()
            XCTAssertEqual(connected.protocolVersion, MCPClient.statelessProtocolVersion)
            let tools = try await client.listTools()
            XCTAssertTrue(tools.isEmpty)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }
}
