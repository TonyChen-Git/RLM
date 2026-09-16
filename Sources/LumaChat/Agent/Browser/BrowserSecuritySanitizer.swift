import Foundation

/// Pure, testable projection boundary between privileged CDP state and data
/// returned to an Agent/model. Browser profiles may contain authenticated
/// state, so raw URLs, headers and structured JavaScript values never cross it.
enum BrowserSecuritySanitizer {
    private static let sensitiveFieldFragments = [
        "authorization", "credential", "cookie", "password", "secret", "token"
    ]
    private static let readableHeaderNames: Set<String> = [
        "accept", "accept-language", "access-control-allow-origin", "age",
        "cache-control", "connection", "content-encoding", "content-language",
        "content-length", "content-type", "date", "etag", "expires", "last-modified",
        "location", "origin", "pragma", "referer", "server", "transfer-encoding",
        "user-agent", "vary"
    ]

    static func url(_ rawValue: String) -> (value: String, truncated: Bool) {
        var value = rawValue
        if var components = URLComponents(string: rawValue), components.scheme != nil {
            components.user = nil
            components.password = nil
            if components.query != nil { components.query = "[REDACTED]" }
            components.fragment = nil
            value = components.string ?? rawValue
        } else if let marker = rawValue.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            value = String(rawValue[..<marker]) + "?[REDACTED]"
        }
        return BrowserBounds.boundedUTF8(
            SecretRedactor().redact(value),
            maximumBytes: BrowserBounds.maximumURLBytes
        )
    }

    static func headers(_ value: JSONValue?) -> [String: String] {
        guard let object = value?.objectValue else { return [:] }
        let redactor = SecretRedactor()
        var result: [String: String] = [:]
        var usedBytes = 0
        for (rawName, rawValue) in object.sorted(by: { $0.key < $1.key }).prefix(128) {
            let name = BrowserBounds.boundedUTF8(rawName, maximumBytes: 256).0
            guard !name.isEmpty,
                  !name.unicodeScalars.contains(
                      where: CharacterSet.controlCharacters.contains
                  ) else { continue }
            let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
            let rendered: String
            if !readableHeaderNames.contains(normalized) || isSensitiveField(normalized) {
                rendered = "[REDACTED]"
            } else if let string = rawValue.stringValue {
                if normalized == "location" || normalized == "referer" || normalized == "origin" {
                    rendered = url(string).value
                } else {
                    rendered = redactor.redact(string)
                }
            } else if let data = try? JSONEncoder().encode(rawValue),
                      let string = String(data: data, encoding: .utf8) {
                rendered = redactor.redact(string)
            } else {
                rendered = ""
            }
            let bounded = BrowserBounds.boundedUTF8(rendered, maximumBytes: 8 * 1_024).0
            let addition = name.utf8.count + bounded.utf8.count
            guard usedBytes + addition <= 64 * 1_024 else { break }
            result[name] = bounded
            usedBytes += addition
        }
        return result
    }

    static func untrustedJSON(_ value: JSONValue) -> JSONValue {
        sanitize(value, fieldName: nil, depth: 0)
    }

    static func modelEnvelope(
        summary: String,
        data: JSONValue,
        maximumBytes: Int
    ) -> String {
        let safeData = untrustedJSON(data)
        let encoded = (try? safeData.jsonString()) ?? "{\"error\":\"projection_failed\"}"
        let escaped = encoded
            .replacingOccurrences(of: "&", with: "\\u0026")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "`", with: "\\u0060")
        let opening = "\n<browser_data trust=\"untrusted\" handling=\"data_only\">\n"
        let closing = "\n</browser_data>"
        let budget = max(
            256,
            maximumBytes - summary.utf8.count - opening.utf8.count - closing.utf8.count - 80
        )
        let bounded = BrowserBounds.boundedUTF8(escaped, maximumBytes: budget)
        let payload: String
        if bounded.1 {
            payload = boundedTruncationPayload(escaped, maximumBytes: budget)
        } else {
            payload = bounded.0
        }
        return summary + opening + payload + closing
    }

    /// Projects only the CDP event fields used by BrowserService before the
    /// event enters the connection's retained ring buffer. Request bodies,
    /// cookie material and unknown event payloads are never retained.
    static func retainedEvent(method: String, params: JSONValue) -> JSONValue? {
        switch method {
        case "Runtime.consoleAPICalled":
            return compactObject([
                "type": params["type"],
                "timestamp": params["timestamp"],
                "args": params["args"]?.arrayValue.map { values in
                    .array(values.prefix(64).map(safeRemoteObject))
                },
                "stackTrace": safeStackTrace(params["stackTrace"])
            ])
        case "Runtime.exceptionThrown":
            let details = params["exceptionDetails"]
            return compactObject([
                "timestamp": params["timestamp"],
                "exceptionDetails": compactObject([
                    "text": details?["text"].map { untrustedJSON($0) },
                    "url": details?["url"].map { untrustedJSON($0) },
                    "lineNumber": details?["lineNumber"],
                    "exception": details?["exception"].map { safeRemoteObject($0) }
                ])
            ])
        case "Log.entryAdded":
            let entry = params["entry"]
            return compactObject([
                "entry": compactObject([
                    "level": entry?["level"],
                    "text": entry?["text"].map { untrustedJSON($0) },
                    "url": entry?["url"].map { untrustedJSON($0) },
                    "lineNumber": entry?["lineNumber"],
                    "timestamp": entry?["timestamp"]
                ])
            ])
        case "Network.requestWillBeSent":
            let request = params["request"]
            let redirect = params["redirectResponse"]
            return compactObject([
                "requestId": params["requestId"],
                "timestamp": params["timestamp"],
                "type": params["type"],
                "request": compactObject([
                    "url": request?["url"].map { untrustedJSON($0) },
                    "method": request?["method"],
                    "headers": .object(
                        headers(request?["headers"]).mapValues { JSONValue.string($0) }
                    )
                ]),
                "redirectResponse": redirect == nil ? nil : compactObject([
                    "url": redirect?["url"].map { untrustedJSON($0) },
                    "status": redirect?["status"]
                ])
            ])
        case "Network.responseReceived":
            let response = params["response"]
            return compactObject([
                "requestId": params["requestId"],
                "timestamp": params["timestamp"],
                "type": params["type"],
                "response": compactObject([
                    "url": response?["url"].map { untrustedJSON($0) },
                    "status": response?["status"],
                    "mimeType": response?["mimeType"],
                    "protocol": response?["protocol"],
                    "headers": .object(
                        headers(response?["headers"]).mapValues { JSONValue.string($0) }
                    ),
                    "encodedDataLength": response?["encodedDataLength"],
                    "timing": compactObject([
                        "receiveHeadersEnd": response?["timing"]?["receiveHeadersEnd"]
                    ])
                ])
            ])
        case "Network.loadingFailed":
            return compactObject([
                "requestId": params["requestId"],
                "timestamp": params["timestamp"],
                "type": params["type"],
                "errorText": params["errorText"].map { untrustedJSON($0) }
            ])
        case "Network.loadingFinished":
            return compactObject([
                "requestId": params["requestId"],
                "timestamp": params["timestamp"],
                "encodedDataLength": params["encodedDataLength"]
            ])
        case "Browser.downloadWillBegin":
            return compactObject([
                "frameId": params["frameId"],
                "guid": params["guid"],
                "url": params["url"].map { untrustedJSON($0) },
                "suggestedFilename": params["suggestedFilename"].map { untrustedJSON($0) }
            ])
        case "Browser.downloadProgress":
            return compactObject([
                "guid": params["guid"],
                "totalBytes": params["totalBytes"],
                "receivedBytes": params["receivedBytes"],
                "state": params["state"]
            ])
        default:
            return nil
        }
    }

    private static func sanitize(
        _ value: JSONValue,
        fieldName: String?,
        depth: Int
    ) -> JSONValue {
        guard depth <= 64 else { return .string("[TRUNCATED]") }
        if let fieldName {
            let normalized = fieldName.lowercased()
            if isSensitiveField(normalized) {
                return .string("[REDACTED]")
            }
            if normalized.contains("url")
                || normalized.contains("uri")
                || normalized == "href"
                || normalized == "location"
                || normalized == "referer" {
                if case .string(let rawURL) = value { return .string(url(rawURL).value) }
            }
        }
        switch value {
        case .object(let object):
            return .object(
                object.reduce(into: [:]) { result, entry in
                    result[entry.key] = sanitize(
                        entry.value,
                        fieldName: entry.key,
                        depth: depth + 1
                    )
                }
            )
        case .array(let values):
            return .array(values.map { sanitize($0, fieldName: nil, depth: depth + 1) })
        case .string(let string):
            let redacted: String
            if let scheme = URLComponents(string: string)?.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                redacted = url(string).value
            } else {
                redacted = SecretRedactor().redact(string)
            }
            return .string(
                BrowserBounds.boundedUTF8(
                    redacted,
                    maximumBytes: BrowserBounds.maximumJavaScriptResultBytes
                ).0
            )
        case .bool, .number, .null:
            return value
        }
    }

    private static func isSensitiveField(_ normalizedName: String) -> Bool {
        sensitiveFieldFragments.contains { normalizedName.contains($0) }
            || normalizedName == "api-key"
            || normalizedName == "x-api-key"
            || normalizedName == "x-auth-token"
            || normalizedName == "x-access-token"
    }

    /// Keeps the truncation marker valid JSON while respecting the tool-result
    /// budget. Directly slicing an encoded JSON stream would leave the model
    /// with malformed data and could accidentally blur the trust boundary.
    private static func boundedTruncationPayload(
        _ escaped: String,
        maximumBytes: Int
    ) -> String {
        func render(prefixBytes: Int) -> String? {
            let prefix = BrowserBounds.boundedUTF8(
                escaped,
                maximumBytes: max(0, prefixBytes)
            ).0
            let wrapper = JSONValue.object([
                "truncated": .bool(true),
                "escaped_json_prefix": .string(prefix),
                "guidance": .string("Narrow the query or use paging.")
            ])
            guard let encoded = try? wrapper.jsonString() else { return nil }
            return encoded
                .replacingOccurrences(of: "&", with: "\\u0026")
                .replacingOccurrences(of: "<", with: "\\u003c")
                .replacingOccurrences(of: ">", with: "\\u003e")
                .replacingOccurrences(of: "`", with: "\\u0060")
        }

        var lower = 0
        var upper = min(escaped.utf8.count, maximumBytes)
        var best = "{\"truncated\":true}"
        while lower <= upper {
            let middle = lower + (upper - lower) / 2
            guard let candidate = render(prefixBytes: middle) else { break }
            if candidate.utf8.count <= maximumBytes {
                best = candidate
                lower = middle + 1
            } else {
                upper = middle - 1
            }
        }
        return best.utf8.count <= maximumBytes ? best : "null"
    }

    private static func compactObject(_ values: [String: JSONValue?]) -> JSONValue {
        .object(values.compactMapValues { $0 })
    }

    private static func safeRemoteObject(_ value: JSONValue) -> JSONValue {
        compactObject([
            "type": value["type"],
            "subtype": value["subtype"],
            "value": value["value"].map { untrustedJSON($0) },
            "description": value["description"].map { untrustedJSON($0) },
            "unserializableValue": value["unserializableValue"].map { untrustedJSON($0) }
        ])
    }

    private static func safeStackTrace(_ value: JSONValue?) -> JSONValue? {
        guard let frames = value?["callFrames"]?.arrayValue else { return nil }
        return .object([
            "callFrames": .array(frames.prefix(32).map { frame in
                compactObject([
                    "url": frame["url"].map { untrustedJSON($0) },
                    "lineNumber": frame["lineNumber"]
                ])
            })
        ])
    }
}
