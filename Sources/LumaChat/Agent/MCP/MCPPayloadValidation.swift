import Foundation

enum MCPPayloadLimits {
    static let maximumWireBytes = 16 * 1_024 * 1_024
    static let maximumContentBytes = 12 * 1_024 * 1_024
    static let maximumTextBytes = 4 * 1_024 * 1_024
    static let maximumBinaryBytes = 8 * 1_024 * 1_024
    static let maximumUnknownContentBytes = 1 * 1_024 * 1_024
    static let maximumJSONDepth = 32
    static let maximumJSONValues = 200_000
    static let maximumCollectionValues = 10_000
    static let maximumStringBytes = 12 * 1_024 * 1_024
    static let maximumKeyBytes = 4_096
    static let maximumMessages = 1_000
    static let maximumResourceContents = 1_000
    static let maximumPromptArguments = 128
    static let maximumPromptArgumentBytes = 1 * 1_024 * 1_024
    static let maximumPromptArgumentValueBytes = 256 * 1_024
    static let maximumURIBytes = 16 * 1_024
    static let maximumNameBytes = 1_024
    static let maximumTitleBytes = 16 * 1_024
    static let maximumDescriptionBytes = 256 * 1_024
    static let maximumMIMETypeBytes = 1_024
    static let maximumCursorBytes = 16 * 1_024
}

enum MCPPayloadValidator {
    static func validateJSON(
        _ value: JSONValue,
        context: String,
        maximumEncodedBytes: Int = MCPPayloadLimits.maximumWireBytes,
        maximumStringBytes: Int = MCPPayloadLimits.maximumStringBytes,
        input: Bool = false
    ) throws {
        let encodedBytes: Int
        do {
            encodedBytes = try MCPWireCodec.encode(value).count
        } catch {
            throw failure(input, "\(context) is not valid JSON.")
        }
        guard encodedBytes <= maximumEncodedBytes else {
            throw failure(input, "\(context) exceeds the \(byteLimit(maximumEncodedBytes)) limit.")
        }

        var stack: [(JSONValue, Int)] = [(value, 0)]
        var valueCount = 0
        while let (current, depth) = stack.popLast() {
            guard depth <= MCPPayloadLimits.maximumJSONDepth else {
                throw failure(input, "\(context) exceeds the JSON nesting limit.")
            }
            valueCount += 1
            guard valueCount <= MCPPayloadLimits.maximumJSONValues else {
                throw failure(input, "\(context) contains too many JSON values.")
            }
            switch current {
            case .string(let text):
                guard text.utf8.count <= maximumStringBytes else {
                    throw failure(input, "\(context) contains an oversized string.")
                }
            case .array(let values):
                guard values.count <= MCPPayloadLimits.maximumCollectionValues else {
                    throw failure(input, "\(context) contains an oversized array.")
                }
                stack.append(contentsOf: values.map { ($0, depth + 1) })
            case .object(let object):
                guard object.count <= MCPPayloadLimits.maximumCollectionValues else {
                    throw failure(input, "\(context) contains an oversized object.")
                }
                guard object.keys.allSatisfy({ $0.utf8.count <= MCPPayloadLimits.maximumKeyBytes }) else {
                    throw failure(input, "\(context) contains an oversized JSON key.")
                }
                stack.append(contentsOf: object.values.map { ($0, depth + 1) })
            case .number(let number):
                guard number.isFinite else {
                    throw failure(input, "\(context) contains a non-finite number.")
                }
            case .bool, .null:
                break
            }
        }
    }

    static func validatePromptRequest(name: String, arguments: [String: String]?) throws {
        try validateName(name, context: "Prompt name", input: true)
        guard let arguments else { return }
        guard arguments.count <= MCPPayloadLimits.maximumPromptArguments else {
            throw MCPError.invalidConfiguration("Prompt arguments exceed the 128-entry limit.")
        }
        var wireArguments: [String: JSONValue] = [:]
        wireArguments.reserveCapacity(arguments.count)
        for (key, value) in arguments {
            try validateName(key, context: "Prompt argument name", input: true)
            guard value.utf8.count <= MCPPayloadLimits.maximumPromptArgumentValueBytes else {
                throw MCPError.invalidConfiguration("A prompt argument value exceeds the 256 KiB limit.")
            }
            wireArguments[key] = .string(value)
        }
        try validateJSON(
            .object(wireArguments),
            context: "Prompt arguments",
            maximumEncodedBytes: MCPPayloadLimits.maximumPromptArgumentBytes,
            maximumStringBytes: MCPPayloadLimits.maximumPromptArgumentValueBytes,
            input: true
        )
    }

    static func validateResourceURI(_ uri: String, input: Bool) throws {
        guard !uri.isEmpty,
              uri.utf8.count <= MCPPayloadLimits.maximumURIBytes,
              !containsControlOrWhitespace(uri),
              let components = URLComponents(string: uri),
              components.scheme?.isEmpty == false else {
            throw failure(input, "Resource URI is missing or invalid.")
        }
    }

    static func validateCursor(_ cursor: String?) throws {
        guard let cursor else { return }
        guard !cursor.isEmpty,
              cursor.utf8.count <= MCPPayloadLimits.maximumCursorBytes,
              !containsControlCharacters(cursor) else {
            throw MCPError.invalidResponse("MCP pagination cursor is invalid or oversized.")
        }
    }

    static func validateTools(_ tools: [MCPToolDescriptor]) throws {
        for tool in tools {
            try validateName(tool.name, context: "Tool name", input: false)
            try validateOptionalString(
                tool.title,
                maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                context: "Tool title"
            )
            try validateOptionalString(
                tool.description,
                maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                context: "Tool description",
                permitsControls: true
            )
            try validateOptionalString(
                tool.annotations?.title,
                maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                context: "Tool annotation title"
            )
        }
    }

    static func validateResources(_ resources: [MCPResourceDescriptor]) throws {
        for resource in resources {
            try validateResourceURI(resource.uri, input: false)
            try validateName(resource.name, context: "Resource name", input: false)
            try validateOptionalString(
                resource.title,
                maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                context: "Resource title"
            )
            try validateOptionalString(
                resource.description,
                maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                context: "Resource description",
                permitsControls: true
            )
            try validateOptionalString(
                resource.mimeType,
                maximumBytes: MCPPayloadLimits.maximumMIMETypeBytes,
                context: "Resource MIME type"
            )
            if let size = resource.size, size < 0 {
                throw MCPError.invalidResponse("Resource size cannot be negative.")
            }
            try validateAnnotations(resource.annotations)
            try validateMetadata(resource.metadata, context: "Resource metadata")
        }
    }

    static func validateResourceTemplates(_ templates: [MCPResourceTemplateDescriptor]) throws {
        for template in templates {
            guard !template.uriTemplate.isEmpty,
                  template.uriTemplate.utf8.count <= MCPPayloadLimits.maximumURIBytes,
                  !containsControlOrWhitespace(template.uriTemplate) else {
                throw MCPError.invalidResponse("Resource template URI is missing or invalid.")
            }
            try validateName(template.name, context: "Resource template name", input: false)
            try validateOptionalString(
                template.title,
                maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                context: "Resource template title"
            )
            try validateOptionalString(
                template.description,
                maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                context: "Resource template description",
                permitsControls: true
            )
            try validateOptionalString(
                template.mimeType,
                maximumBytes: MCPPayloadLimits.maximumMIMETypeBytes,
                context: "Resource template MIME type"
            )
            try validateAnnotations(template.annotations)
            try validateMetadata(template.metadata, context: "Resource template metadata")
        }
    }

    static func validatePrompts(_ prompts: [MCPPromptDescriptor]) throws {
        for prompt in prompts {
            try validateName(prompt.name, context: "Prompt name", input: false)
            try validateOptionalString(
                prompt.title,
                maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                context: "Prompt title"
            )
            try validateOptionalString(
                prompt.description,
                maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                context: "Prompt description",
                permitsControls: true
            )
            let arguments = prompt.arguments ?? []
            guard arguments.count <= MCPPayloadLimits.maximumPromptArguments else {
                throw MCPError.invalidResponse("A prompt declares too many arguments.")
            }
            for argument in arguments {
                try validateName(argument.name, context: "Prompt argument name", input: false)
                try validateOptionalString(
                    argument.title,
                    maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                    context: "Prompt argument title"
                )
                try validateOptionalString(
                    argument.description,
                    maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                    context: "Prompt argument description",
                    permitsControls: true
                )
            }
        }
    }

    static func parseResourceReadResult(_ value: JSONValue) throws -> MCPResourceReadResult {
        guard let object = value.objectValue,
              let rawContents = object["contents"]?.arrayValue else {
            throw MCPError.invalidResponse("resources/read omitted its contents array.")
        }
        guard rawContents.count <= MCPPayloadLimits.maximumResourceContents else {
            throw MCPError.invalidResponse("resources/read returned too many content items.")
        }

        var totalBytes = 0
        let contents = try rawContents.map {
            try parseResourceContent($0, totalBytes: &totalBytes, context: "resources/read content")
        }
        return MCPResourceReadResult(
            contents: contents,
            metadata: try parseMetadata(object["_meta"], context: "resources/read metadata")
        )
    }

    static func parsePromptGetResult(_ value: JSONValue) throws -> MCPPromptGetResult {
        guard let object = value.objectValue,
              let rawMessages = object["messages"]?.arrayValue else {
            throw MCPError.invalidResponse("prompts/get omitted its messages array.")
        }
        guard rawMessages.count <= MCPPayloadLimits.maximumMessages else {
            throw MCPError.invalidResponse("prompts/get returned too many messages.")
        }
        let description = try optionalString(
            object["description"],
            maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
            context: "Prompt result description",
            permitsControls: true
        )

        var totalBytes = 0
        var messages: [MCPPromptMessage] = []
        messages.reserveCapacity(rawMessages.count)
        for rawMessage in rawMessages {
            guard let message = rawMessage.objectValue,
                  let rawRole = message["role"]?.stringValue,
                  let role = MCPRole(rawValue: rawRole),
                  let content = message["content"] else {
                throw MCPError.invalidResponse("prompts/get returned a malformed message.")
            }
            messages.append(
                MCPPromptMessage(
                    role: role,
                    content: try parsePromptContent(content, totalBytes: &totalBytes)
                )
            )
        }
        return MCPPromptGetResult(
            description: description,
            messages: messages,
            metadata: try parseMetadata(object["_meta"], context: "prompts/get metadata")
        )
    }

    private static func parsePromptContent(
        _ value: JSONValue,
        totalBytes: inout Int
    ) throws -> MCPPromptContentBlock {
        guard let object = value.objectValue,
              let type = object["type"]?.stringValue,
              !type.isEmpty,
              type.utf8.count <= MCPPayloadLimits.maximumNameBytes else {
            throw MCPError.invalidResponse("Prompt content is missing a valid type.")
        }
        let annotations = try parseAnnotations(object["annotations"])
        let metadata = try parseMetadata(object["_meta"], context: "Prompt content metadata")

        switch type {
        case "text":
            let text = try requiredString(
                object["text"],
                maximumBytes: MCPPayloadLimits.maximumTextBytes,
                context: "Text content",
                permitsControls: true,
                permitsEmpty: true
            )
            try consume(text.utf8.count, total: &totalBytes)
            return .text(MCPTextContent(text: text, annotations: annotations, metadata: metadata))
        case "image", "audio":
            let mimeType = try requiredString(
                object["mimeType"],
                maximumBytes: MCPPayloadLimits.maximumMIMETypeBytes,
                context: "Binary content MIME type"
            )
            let data = try decodeBase64(object["data"], context: "\(type) content")
            try consume(data.count, total: &totalBytes)
            let content = MCPBinaryContent(
                data: data,
                mimeType: mimeType,
                annotations: annotations,
                metadata: metadata
            )
            return type == "image" ? .image(content) : .audio(content)
        case "resource_link":
            let uri = try requiredString(
                object["uri"],
                maximumBytes: MCPPayloadLimits.maximumURIBytes,
                context: "Resource link URI"
            )
            try validateResourceURI(uri, input: false)
            let name = try requiredString(
                object["name"],
                maximumBytes: MCPPayloadLimits.maximumNameBytes,
                context: "Resource link name"
            )
            let size = try optionalNonnegativeInteger(object["size"], context: "Resource link size")
            let link = MCPResourceLinkContent(
                uri: uri,
                name: name,
                title: try optionalString(
                    object["title"],
                    maximumBytes: MCPPayloadLimits.maximumTitleBytes,
                    context: "Resource link title"
                ),
                description: try optionalString(
                    object["description"],
                    maximumBytes: MCPPayloadLimits.maximumDescriptionBytes,
                    context: "Resource link description",
                    permitsControls: true
                ),
                mimeType: try optionalString(
                    object["mimeType"],
                    maximumBytes: MCPPayloadLimits.maximumMIMETypeBytes,
                    context: "Resource link MIME type"
                ),
                size: size,
                annotations: annotations,
                metadata: metadata
            )
            return .resourceLink(link)
        case "resource":
            guard let rawResource = object["resource"] else {
                throw MCPError.invalidResponse("Embedded resource content omitted resource.")
            }
            let resource = try parseResourceContent(
                rawResource,
                totalBytes: &totalBytes,
                context: "Embedded resource"
            )
            return .resource(
                MCPEmbeddedResourceContent(
                    resource: resource,
                    annotations: annotations,
                    metadata: metadata
                )
            )
        default:
            let encodedCount: Int
            do {
                encodedCount = try MCPWireCodec.encode(value).count
            } catch {
                throw MCPError.invalidResponse("Unknown prompt content is not valid JSON.")
            }
            guard encodedCount <= MCPPayloadLimits.maximumUnknownContentBytes else {
                throw MCPError.invalidResponse("Unknown prompt content exceeds the 1 MiB limit.")
            }
            try consume(encodedCount, total: &totalBytes)
            return .unknown(type: type, value: value)
        }
    }

    private static func parseResourceContent(
        _ value: JSONValue,
        totalBytes: inout Int,
        context: String
    ) throws -> MCPResourceContent {
        guard let object = value.objectValue else {
            throw MCPError.invalidResponse("\(context) must be an object.")
        }
        let uri = try requiredString(
            object["uri"],
            maximumBytes: MCPPayloadLimits.maximumURIBytes,
            context: "\(context) URI"
        )
        try validateResourceURI(uri, input: false)
        let mimeType = try optionalString(
            object["mimeType"],
            maximumBytes: MCPPayloadLimits.maximumMIMETypeBytes,
            context: "\(context) MIME type"
        )
        let metadata = try parseMetadata(object["_meta"], context: "\(context) metadata")
        let hasText = object["text"] != nil
        let hasBlob = object["blob"] != nil
        guard hasText != hasBlob else {
            throw MCPError.invalidResponse("\(context) must contain exactly one of text or blob.")
        }
        if hasText {
            let text = try requiredString(
                object["text"],
                maximumBytes: MCPPayloadLimits.maximumTextBytes,
                context: "\(context) text",
                permitsControls: true,
                permitsEmpty: true
            )
            try consume(text.utf8.count, total: &totalBytes)
            return .text(
                MCPTextResourceContents(
                    uri: uri,
                    mimeType: mimeType,
                    text: text,
                    metadata: metadata
                )
            )
        }

        let data = try decodeBase64(object["blob"], context: "\(context) blob")
        try consume(data.count, total: &totalBytes)
        return .blob(
            MCPBlobResourceContents(
                uri: uri,
                mimeType: mimeType,
                data: data,
                metadata: metadata
            )
        )
    }

    private static func parseAnnotations(_ value: JSONValue?) throws -> MCPContentAnnotations? {
        guard let value else { return nil }
        guard let object = value.objectValue else {
            throw MCPError.invalidResponse("Content annotations must be an object.")
        }
        let audience: [MCPRole]?
        if let rawAudience = object["audience"] {
            guard let roles = rawAudience.arrayValue, roles.count <= 2 else {
                throw MCPError.invalidResponse("Content annotation audience is malformed.")
            }
            audience = try roles.map { value in
                guard let rawRole = value.stringValue, let role = MCPRole(rawValue: rawRole) else {
                    throw MCPError.invalidResponse("Content annotation audience contains an invalid role.")
                }
                return role
            }
        } else {
            audience = nil
        }

        let priority: Double?
        if let rawPriority = object["priority"] {
            guard case .number(let value) = rawPriority,
                  value.isFinite,
                  (0...1).contains(value) else {
                throw MCPError.invalidResponse("Content annotation priority must be between zero and one.")
            }
            priority = value
        } else {
            priority = nil
        }
        let lastModified = try optionalString(
            object["lastModified"],
            maximumBytes: MCPPayloadLimits.maximumNameBytes,
            context: "Content annotation timestamp"
        )
        try validateTimestamp(lastModified)
        return MCPContentAnnotations(
            audience: audience,
            priority: priority,
            lastModified: lastModified
        )
    }

    private static func validateAnnotations(_ annotations: MCPContentAnnotations?) throws {
        guard let annotations else { return }
        if let audience = annotations.audience, audience.count > 2 {
            throw MCPError.invalidResponse("Content annotation audience is oversized.")
        }
        if let priority = annotations.priority,
           (!priority.isFinite || !(0...1).contains(priority)) {
            throw MCPError.invalidResponse("Content annotation priority must be between zero and one.")
        }
        try validateOptionalString(
            annotations.lastModified,
            maximumBytes: MCPPayloadLimits.maximumNameBytes,
            context: "Content annotation timestamp"
        )
        try validateTimestamp(annotations.lastModified)
    }

    private static func parseMetadata(_ value: JSONValue?, context: String) throws -> JSONValue? {
        guard let value else { return nil }
        guard case .object = value else {
            throw MCPError.invalidResponse("\(context) must be an object.")
        }
        return value
    }

    private static func validateMetadata(_ value: JSONValue?, context: String) throws {
        guard let value else { return }
        guard case .object = value else {
            throw MCPError.invalidResponse("\(context) must be an object.")
        }
    }

    private static func decodeBase64(_ value: JSONValue?, context: String) throws -> Data {
        guard let encoded = value?.stringValue,
              encoded.utf8.count <= MCPPayloadLimits.maximumStringBytes,
              encoded.utf8.count.isMultiple(of: 4),
              let data = Data(base64Encoded: encoded),
              data.count <= MCPPayloadLimits.maximumBinaryBytes,
              data.base64EncodedString() == encoded else {
            throw MCPError.invalidResponse("\(context) is invalid or exceeds the binary limit.")
        }
        return data
    }

    private static func consume(_ bytes: Int, total: inout Int) throws {
        let (newTotal, overflow) = total.addingReportingOverflow(bytes)
        guard !overflow, newTotal <= MCPPayloadLimits.maximumContentBytes else {
            throw MCPError.invalidResponse("MCP content exceeds the 12 MiB cumulative limit.")
        }
        total = newTotal
    }

    private static func requiredString(
        _ value: JSONValue?,
        maximumBytes: Int,
        context: String,
        permitsControls: Bool = false,
        permitsEmpty: Bool = false
    ) throws -> String {
        guard let string = value?.stringValue,
              (permitsEmpty || !string.isEmpty),
              string.utf8.count <= maximumBytes,
              (permitsControls || !containsControlCharacters(string)) else {
            throw MCPError.invalidResponse("\(context) is missing, invalid, or oversized.")
        }
        return string
    }

    private static func optionalString(
        _ value: JSONValue?,
        maximumBytes: Int,
        context: String,
        permitsControls: Bool = false
    ) throws -> String? {
        guard let value else { return nil }
        guard let string = value.stringValue,
              string.utf8.count <= maximumBytes,
              (permitsControls || !containsControlCharacters(string)) else {
            throw MCPError.invalidResponse("\(context) is invalid or oversized.")
        }
        return string
    }

    private static func optionalNonnegativeInteger(
        _ value: JSONValue?,
        context: String
    ) throws -> Int64? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              let integer = Int64(exactly: number) else {
            throw MCPError.invalidResponse("\(context) must be a nonnegative integer.")
        }
        return integer
    }

    private static func validateName(_ value: String, context: String, input: Bool) throws {
        guard !value.isEmpty,
              value.utf8.count <= MCPPayloadLimits.maximumNameBytes,
              !containsControlCharacters(value) else {
            throw failure(input, "\(context) is missing, invalid, or oversized.")
        }
    }

    private static func validateOptionalString(
        _ value: String?,
        maximumBytes: Int,
        context: String,
        permitsControls: Bool = false
    ) throws {
        guard let value else { return }
        guard value.utf8.count <= maximumBytes,
              (permitsControls || !containsControlCharacters(value)) else {
            throw MCPError.invalidResponse("\(context) is invalid or oversized.")
        }
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func containsControlOrWhitespace(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
                || CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func validateTimestamp(_ value: String?) throws {
        guard let value else { return }
        let standard = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard standard.date(from: value) != nil || fractional.date(from: value) != nil else {
            throw MCPError.invalidResponse("Content annotation timestamp is not ISO 8601.")
        }
    }

    private static func failure(_ input: Bool, _ message: String) -> MCPError {
        input ? .invalidConfiguration(message) : .invalidResponse(message)
    }

    private static func byteLimit(_ bytes: Int) -> String {
        guard bytes.isMultiple(of: 1_024 * 1_024) else { return "\(bytes)-byte" }
        return "\(bytes / (1_024 * 1_024)) MiB"
    }
}
