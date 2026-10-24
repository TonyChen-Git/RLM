import Foundation

/// Implements the 2026-07-28 Streamable HTTP `x-mcp-header` contract.
/// Annotation discovery is deliberately static; it never resolves references or
/// evaluates schema branches. These headers are routing metadata, not authority.
enum MCPHTTPHeaderProjection {
    private static let maximumRawValueBytes = 8 * 1_024
    private static let maximumWireValueBytes = 12 * 1_024
    private static let maximumHeaderBytes = 32 * 1_024
    private static let maximumHeaders = 64
    private static let maximumNameBytes = 128
    private static let maximumSafeInteger = 9_007_199_254_740_991.0

    static func validate(tool: MCPToolDescriptor) throws {
        _ = try projections(for: tool)
    }

    static func headers(
        for tool: MCPToolDescriptor,
        arguments: [String: JSONValue]
    ) throws -> [String: String] {
        let projections = try projections(for: tool)
        var headers: [String: String] = [:]
        var totalBytes = 0
        for projection in projections {
            var value: JSONValue? = .object(arguments)
            for component in projection.path {
                value = value?.objectValue?[component]
            }
            // A null argument has the same header semantics as an absent value,
            // including when the server marked the property as required.
            guard let value, value != .null else { continue }
            let rawValue: String
            switch (projection.type, value) {
            case (.string, .string(let string)):
                rawValue = string
            case (.boolean, .bool(let bool)):
                rawValue = bool ? "true" : "false"
            case (.integer, .number(let number)):
                guard number.isFinite,
                      number.rounded(.towardZero) == number,
                      abs(number) <= maximumSafeInteger else {
                    throw MCPError.invalidConfiguration("MCP header integer must be a safe, finite integer.")
                }
                rawValue = String(Int64(number))
            default:
                throw MCPError.invalidConfiguration("MCP header argument does not match its declared primitive type.")
            }
            let encoded = try encodedValue(rawValue)
            totalBytes += projection.headerName.utf8.count + encoded.utf8.count + 4
            guard totalBytes <= maximumHeaderBytes else {
                throw MCPError.invalidConfiguration("MCP parameter headers exceed the aggregate size limit.")
            }
            headers[projection.headerName] = encoded
        }
        return headers
    }

    /// Also used for Mcp-Name. The sentinel is case-sensitive and must itself be
    /// escaped when supplied literally, so decoding cannot change the value.
    static func encodedValue(_ value: String) throws -> String {
        guard value.utf8.prefix(maximumRawValueBytes + 1).count <= maximumRawValueBytes else {
            throw MCPError.invalidConfiguration("MCP header value exceeds the size limit.")
        }
        let bytes = value.utf8
        let isPlainASCII = bytes.allSatisfy { $0 == 9 || (32...126).contains($0) }
        let hasBoundaryWhitespace = bytes.first.map { $0 == 9 || $0 == 32 } == true
            || bytes.last.map { $0 == 9 || $0 == 32 } == true
        let isSentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        let encoded = isPlainASCII && !hasBoundaryWhitespace && !isSentinel
            ? value
            : "=?base64?\(Data(bytes).base64EncodedString())?="
        guard encoded.utf8.count <= maximumWireValueBytes else {
            throw MCPError.invalidConfiguration("Encoded MCP header value exceeds the size limit.")
        }
        return encoded
    }

    private enum Primitive: String {
        case string, integer, boolean
    }

    private struct Projection {
        var path: [String]
        var headerName: String
        var type: Primitive
    }

    private static func projections(for tool: MCPToolDescriptor) throws -> [Projection] {
        guard tool.inputSchema.objectValue != nil else {
            throw MCPError.invalidResponse("MCP tool input schema must be an object.")
        }
        var scanner = SchemaScanner()
        try scanner.visit(tool.inputSchema, path: [], depth: 0)
        return scanner.projections
    }

    private struct SchemaScanner {
        var projections: [Projection] = []
        var names = Set<String>()
        var nodes = 0
        var bytes = 0
        private enum Context {
            case schema, schemaMap, schemaArray, data
        }

        private static let schemaMapKeywords: Set<String> = [
            "$defs", "definitions", "patternProperties", "dependentSchemas", "dependencies"
        ]
        private static let schemaArrayKeywords: Set<String> = [
            "oneOf", "anyOf", "allOf", "prefixItems"
        ]
        private static let schemaKeywords: Set<String> = [
            "not", "if", "then", "else", "items", "contains", "additionalItems",
            "additionalProperties", "unevaluatedProperties", "unevaluatedItems",
            "propertyNames", "contentSchema"
        ]

        mutating func visit(_ value: JSONValue, path: [String]?, depth: Int) throws {
            try visit(value, path: path, depth: depth, context: .schema)
        }

        private mutating func visit(
            _ value: JSONValue,
            path: [String]?,
            depth: Int,
            context: Context
        ) throws {
            nodes += 1
            guard depth <= 64, nodes <= 8_192 else {
                throw MCPError.invalidResponse("MCP tool schema exceeds projection complexity limits.")
            }
            switch value {
            case .object(let object):
                guard object.count <= 8_192 else {
                    throw MCPError.invalidResponse("MCP tool schema exceeds projection complexity limits.")
                }
                if context == .schema, let annotation = object["x-mcp-header"] {
                    guard let path, !path.isEmpty,
                          let rawType = object["type"]?.stringValue,
                          let type = Primitive(rawValue: rawType),
                          let name = annotation.stringValue else {
                        throw MCPError.invalidResponse("MCP header annotation requires a static properties path and primitive string, integer, or boolean type.")
                    }
                    try add(name: name, path: path, type: type)
                }
                let isObject = object["type"] == nil || object["type"] == .string("object")
                    || object["type"]?.arrayValue?.contains(.string("object")) == true
                let childPath = isObject ? path : nil
                // Sort for stable diagnostics and deterministic extraction.
                for key in object.keys.sorted() {
                    try consume(key)
                    guard let child = object[key] else { continue }
                    if context == .schema, key == "properties", case .object(let properties) = child {
                        // This dictionary contains property names, not schema
                        // keywords: a property may itself be named x-mcp-header.
                        nodes += 1
                        guard depth < 64, nodes <= 8_192, properties.count <= 8_192 else {
                            throw MCPError.invalidResponse("MCP tool schema exceeds projection complexity limits.")
                        }
                        for name in properties.keys.sorted() {
                            try consume(name)
                            if let property = properties[name] {
                                try visit(
                                    property, path: childPath.map { $0 + [name] },
                                    depth: depth + 2, context: .schema
                                )
                            }
                        }
                    } else {
                        let childContext: Context
                        if context == .schemaMap {
                            // Map keys are names, including literal x-mcp-header;
                            // only their values are schemas.
                            childContext = .schema
                        } else if context == .schema {
                            if Self.schemaMapKeywords.contains(key) {
                                childContext = .schemaMap
                            } else if Self.schemaArrayKeywords.contains(key) {
                                childContext = .schemaArray
                            } else if Self.schemaKeywords.contains(key) {
                                childContext = .schema
                            } else {
                                // Values of examples/default/const/enum and
                                // unknown annotations are data, not subschemas.
                                childContext = .data
                            }
                        } else {
                            childContext = .data
                        }
                        try visit(child, path: nil, depth: depth + 1, context: childContext)
                    }
                }
            case .array(let values):
                guard values.count <= 8_192 else {
                    throw MCPError.invalidResponse("MCP tool schema exceeds projection complexity limits.")
                }
                for child in values {
                    try visit(
                        child, path: nil, depth: depth + 1,
                        context: context == .schemaArray || context == .schema ? .schema : .data
                    )
                }
            case .string(let string):
                try consume(string)
            case .number, .bool, .null:
                break
            }
        }

        private mutating func consume(_ string: String) throws {
            bytes += string.utf8.prefix(512 * 1_024 + 1).count
            guard bytes <= 512 * 1_024 else {
                throw MCPError.invalidResponse("MCP tool schema exceeds the projection size limit.")
            }
        }

        private mutating func add(name: String, path: [String], type: Primitive) throws {
            let nameBytes = name.utf8
            guard !nameBytes.isEmpty, nameBytes.prefix(maximumNameBytes + 1).count <= maximumNameBytes,
                  nameBytes.allSatisfy(Self.isTokenByte) else {
                throw MCPError.invalidResponse("MCP header annotation must be a bounded HTTP field-name token.")
            }
            guard names.insert(name.lowercased()).inserted else {
                throw MCPError.invalidResponse("MCP header annotations must have case-insensitively unique names.")
            }
            guard projections.count < maximumHeaders else {
                throw MCPError.invalidResponse("MCP tool declares too many parameter headers.")
            }
            projections.append(Projection(path: path, headerName: "Mcp-Param-\(name)", type: type))
        }

        private static func isTokenByte(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
                || [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains(byte)
        }
    }
}
