import Foundation

protocol MCPTransport: Sendable {
    func start() async throws
    func send(_ request: MCPJSONRPCRequest) async throws -> MCPJSONRPCResponse?
    func stop() async
}

protocol MCPTransportFactory: Sendable {
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport
}

struct MCPDefaultTransportFactory: MCPTransportFactory {
    func makeTransport(for configuration: MCPServerConfiguration) throws -> any MCPTransport {
        switch configuration.transport {
        case .stdio(let stdio):
            try MCPStdioPolicy.validate(stdio)
            return MCPStdioTransport(
                serverID: configuration.id,
                configuration: stdio,
                allowsNetwork: configuration.permissionLevel == .network
                    || configuration.permissionLevel == .dangerous
            )
        case .streamableHTTP(let http):
            try MCPHTTPPolicy.validate(http.endpoint)
            return MCPStreamableHTTPTransport(configuration: http)
        }
    }
}

enum MCPStdioPolicy {
    static func validate(_ configuration: MCPStdioConfiguration) throws {
        let command = configuration.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !command.contains("\0") else {
            throw MCPError.invalidConfiguration("STDIO command is empty or invalid.")
        }
        guard !configuration.arguments.contains(where: { $0.contains("\0") }) else {
            throw MCPError.invalidConfiguration("STDIO arguments contain an invalid NUL byte.")
        }
        guard let rawDirectory = configuration.workingDirectory?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !rawDirectory.isEmpty else { return }
        guard rawDirectory.hasPrefix("/"), !rawDirectory.contains("\0") else {
            throw MCPError.invalidConfiguration("STDIO working directory must be an absolute path.")
        }
        let directory = URL(fileURLWithPath: rawDirectory, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MCPError.invalidConfiguration("STDIO working directory does not exist.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let projectTemporaryRoot = AppPaths.projectTemporaryRoot
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard directory.path != "/", directory.path != home.path else {
            throw MCPError.invalidConfiguration(
                "STDIO working directory must be a focused project folder, not a filesystem or home root."
            )
        }
        guard directory.path != projectTemporaryRoot.path,
              !directory.path.hasPrefix(projectTemporaryRoot.path + "/") else {
            throw MCPError.invalidConfiguration(
                "Shared project tmp storage cannot be exposed as an MCP working directory."
            )
        }
    }
}

enum MCPHTTPPolicy {
    static func validate(_ endpoint: URL) throws {
        guard endpoint.user == nil, endpoint.password == nil else {
            throw MCPError.invalidConfiguration("MCP credentials must use protected headers, not URL userinfo.")
        }
        guard endpoint.query == nil, endpoint.fragment == nil else {
            throw MCPError.invalidConfiguration("MCP endpoint query/fragment is not persisted; use protected headers.")
        }
        guard let scheme = endpoint.scheme?.lowercased(), let host = endpoint.host?.lowercased() else {
            throw MCPError.invalidConfiguration("Streamable HTTP endpoint is incomplete.")
        }
        if scheme == "https" { return }
        guard scheme == "http", isLoopback(host) else {
            throw MCPError.invalidConfiguration("Plain HTTP is allowed only for a strict loopback endpoint.")
        }
    }

    private static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts.first == "127",
              parts.allSatisfy({ part in
                  guard let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else { return false }
        return true
    }
}

enum MCPWireCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func value<T: Encodable>(from value: T) throws -> JSONValue {
        try decode(JSONValue.self, from: encode(value))
    }

    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        try decode(type, from: encode(value))
    }
}

/// MCP stdio uses one complete JSON-RPC message per line. The framer accepts
/// arbitrary pipe chunking and deliberately caps an unterminated line.
struct MCPNewlineFramer: Sendable {
    private(set) var buffer = Data()
    var maximumFrameBytes = 16 * 1_024 * 1_024

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        guard buffer.count <= maximumFrameBytes || buffer.contains(0x0A) else {
            buffer.removeAll(keepingCapacity: false)
            throw MCPError.invalidResponse("STDIO JSON frame exceeds the 16 MiB limit.")
        }

        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var frame = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if frame.last == 0x0D { frame = frame.dropLast() }
            guard !frame.isEmpty else { continue }
            guard frame.count <= maximumFrameBytes else {
                throw MCPError.invalidResponse("STDIO JSON frame exceeds the 16 MiB limit.")
            }
            frames.append(Data(frame))
        }
        return frames
    }
}

enum MCPSSEParser {
    static func responseEvents(from data: Data) throws -> [MCPJSONRPCResponse] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.invalidResponse("SSE response is not UTF-8.")
        }

        var responses: [MCPJSONRPCResponse] = []
        var dataLines: [String] = []

        func decodeEvent() throws {
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            dataLines.removeAll(keepingCapacity: true)
            guard payload != "[DONE]", let bytes = payload.data(using: .utf8) else { return }
            let response = try MCPWireCodec.decode(MCPJSONRPCResponse.self, from: bytes)
            if response.result != nil || response.error != nil {
                responses.append(response)
            }
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .newlines)
            if line.isEmpty {
                try decodeEvent()
            } else if line.hasPrefix("data:") {
                var value = String(line.dropFirst(5))
                if value.first == " " { value.removeFirst() }
                dataLines.append(value)
            }
        }
        try decodeEvent()
        return responses
    }
}

extension MCPJSONRPCID {
    var jsonValue: JSONValue {
        switch self {
        case .integer(let value): .number(Double(value))
        case .string(let value): .string(value)
        case .null: .null
        }
    }
}
