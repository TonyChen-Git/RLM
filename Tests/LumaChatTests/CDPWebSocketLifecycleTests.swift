import Foundation
import Network
import XCTest

@testable import LumaChat

/// A real loopback WebSocket peer. It exercises URLSession framing and the CDP
/// receive loop without starting Chrome or using any external service.
private final class CDPLoopbackPeer: @unchecked Sendable {
    private enum PeerError: Error { case missingMethod(String) }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LumaChatTests.CDPLoopbackPeer")
    private var connections: [NWConnection] = []
    private var startResolved = false
    private var observedMethods: Set<String> = []
    private var heldReplies: [String: (connection: NWConnection, data: Data)] = [:]

    init() throws {
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // All listener and connection callbacks run on this serial queue.
            listener.stateUpdateHandler = { [self] state in
                guard !startResolved else { return }
                switch state {
                case .ready:
                    startResolved = true
                    continuation.resume(returning: URL(
                        string: "ws://127.0.0.1:\(listener.port!.rawValue)/cdp"
                    )!)
                case .failed(let error):
                    startResolved = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connections.append(connection)
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                listener.cancel()
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                connections.forEach { $0.cancel() }
                connections.removeAll()
                heldReplies.removeAll()
                continuation.resume()
            }
        }
    }

    func waitForMethod(_ method: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            let observed = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    continuation.resume(returning: observedMethods.contains(method))
                }
            }
            if observed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PeerError.missingMethod(method)
    }

    func releaseReply(for method: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard let reply = heldReplies.removeValue(forKey: method) else {
                    continuation.resume(throwing: PeerError.missingMethod(method))
                    return
                }
                send(reply.data, on: reply.connection) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }

    private func send(
        _ response: Data, on connection: NWConnection,
        completion: @escaping @Sendable (NWError?) -> Void = { _ in }
    ) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "cdp-response", metadata: [metadata]
        )
        connection.send(
            content: response, contentContext: context, isComplete: true,
            completion: .contentProcessed(completion)
        )
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [self] data, _, _, error in
            guard error == nil else { return }
            if let data,
               let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let identifier = command["id"],
               let method = command["method"] as? String,
               let response = try? JSONSerialization.data(withJSONObject: [
                   "id": identifier, "result": ["method": method]
               ]) {
                observedMethods.insert(method)
                if method == "Test.hang" {
                    heldReplies[method] = (connection, response)
                } else {
                    send(response, on: connection)
                }
            }
            receive(connection)
        }
    }
}

final class CDPWebSocketLifecycleTests: XCTestCase, @unchecked Sendable {
    func testUnexpectedReceiveCancellationClosesConnectionAndFailsPendingCommand() async throws {
        let peer = try CDPLoopbackPeer()
        addTeardownBlock { await peer.stop() }
        let connection = try CDPWebSocketConnection(
            endpoint: await peer.start(),
            receiveMessage: {
                try await peer.waitForMethod("Test.hang")
                throw CancellationError()
            }
        )
        addTeardownBlock { await connection.close() }
        try await connection.start()
        do {
            _ = try await connection.command("Test.hang", timeout: 1)
            XCTFail("Canceled receive loop unexpectedly returned a result")
        } catch {
            XCTAssertEqual(error as? BrowserError, .websocketClosed)
        }
        // Also assert this barrier outside the injected receive function, so a
        // barrier timeout cannot masquerade as the intended cancellation fault.
        try await peer.waitForMethod("Test.hang")
        let open = await connection.isOpen()
        XCTAssertFalse(open, "A connection without a receive loop must not be reused")
    }

    func testConnectionRemainsUsableAfterCommandTimeoutLengthIdle() async throws {
        let peer = try CDPLoopbackPeer()
        addTeardownBlock { await peer.stop() }
        let connection = try CDPWebSocketConnection(endpoint: await peer.start())
        addTeardownBlock { await connection.close() }
        try await connection.start()
        let first = try await connection.command("Test.first", timeout: 2)
        XCTAssertEqual(first["method"]?.stringValue, "Test.first")
        // Browser approvals can leave the persistent browser-level socket
        // idle longer than an individual CDP command's maximum timeout.
        try await Task.sleep(for: .seconds(32))
        let second = try await connection.command("Test.second", timeout: 2)
        XCTAssertEqual(second["method"]?.stringValue, "Test.second")
    }

    func testCancelingCreatorDoesNotStopPersistentReceiveLoop() async throws {
        let peer = try CDPLoopbackPeer()
        addTeardownBlock { await peer.stop() }
        let connection = try CDPWebSocketConnection(endpoint: await peer.start())
        addTeardownBlock { await connection.close() }
        let creator = Task {
            try await connection.start()
            _ = try await connection.command("Test.open", timeout: 2)
            try await Task.sleep(for: .seconds(60))
        }
        defer { creator.cancel() }
        try await peer.waitForMethod("Test.open")
        _ = try await connection.command("Test.ready", timeout: 2)
        creator.cancel()
        _ = await creator.result
        let response = try await connection.command("Test.afterCancel", timeout: 2)
        XCTAssertEqual(response["method"]?.stringValue, "Test.afterCancel")
    }

    func testCanceledCommandDoesNotConsumeNextResponse() async throws {
        let peer = try CDPLoopbackPeer()
        addTeardownBlock { await peer.stop() }
        let connection = try CDPWebSocketConnection(endpoint: await peer.start())
        addTeardownBlock { await connection.close() }
        try await connection.start()
        let pending = Task { try await connection.command("Test.hang", timeout: 5) }
        defer { pending.cancel() }
        try await peer.waitForMethod("Test.hang")
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Canceled CDP command unexpectedly returned a result")
        } catch is CancellationError { }
        // The peer really sends the canceled command's late response before the
        // new reply. Correlation must discard its ID and return the new result.
        try await peer.releaseReply(for: "Test.hang")
        let response = try await connection.command("Test.afterCancel", timeout: 2)
        XCTAssertEqual(response["method"]?.stringValue, "Test.afterCancel")
    }

    func testPeerClosureFailsPendingCommandAndClosesConnection() async throws {
        let peer = try CDPLoopbackPeer()
        addTeardownBlock { await peer.stop() }
        let connection = try CDPWebSocketConnection(endpoint: await peer.start())
        addTeardownBlock { await connection.close() }
        try await connection.start()
        _ = try await connection.command("Test.ready", timeout: 2)
        let pending = Task { try await connection.command("Test.hang", timeout: 5) }
        defer { pending.cancel() }
        try await peer.waitForMethod("Test.hang")
        await peer.stop()
        do {
            _ = try await pending.value
            XCTFail("Closed peer unexpectedly returned a result")
        } catch {
            XCTAssertEqual(error as? BrowserError, .websocketClosed)
        }
        let open = await connection.isOpen()
        XCTAssertFalse(open)
    }
}
