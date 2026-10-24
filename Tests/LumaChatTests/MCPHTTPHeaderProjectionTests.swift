import Foundation
import XCTest
@testable import LumaChat

final class MCPHTTPHeaderProjectionTests: XCTestCase {
    func testExtractsExactNestedPathsAndPrimitiveValues() throws {
        let descriptor = tool(properties: [
            "routing": .objectSchema(properties: ["region": parameter("string", "Region")]),
            "routing.region": parameter("integer", "Shard"),
            "enabled": parameter("boolean", "Enabled")
        ])
        let headers = try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [
            "routing": .object(["region": .string("us-west1")]),
            "routing.region": .number(-42), "enabled": .bool(false)
        ])
        XCTAssertEqual(headers, [
            "Mcp-Param-Region": "us-west1", "Mcp-Param-Shard": "-42", "Mcp-Param-Enabled": "false"
        ])
    }

    func testAbsentAndNullValuesOmitHeadersEvenForRequiredProperties() throws {
        let descriptor = tool(schema: .objectSchema(properties: [
            "optional": parameter("string", "Optional"),
            "required": parameter("integer", "Required"),
            "nested": .objectSchema(properties: ["value": parameter("boolean", "Nested")])
        ], required: ["required"]))
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [:]), [:])
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [
            "optional": .null, "required": .null, "nested": .null
        ]), [:])
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [
            "nested": .object(["value": .null])
        ]), [:])
    }

    func testUnannotatedPropertiesAndLiteralKeywordPropertyNames() throws {
        let descriptor = tool(properties: [
            "x-mcp-header": parameter("string", "Literal"),
            "unannotated": .object(["type": .string("number")])
        ])
        XCTAssertNoThrow(try MCPHTTPHeaderProjection.validate(tool: descriptor))
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [
            "x-mcp-header": .string("value"), "unannotated": .number(1.5)
        ]), ["Mcp-Param-Literal": "value"])
    }

    func testPlainASCIIAndInteriorTabRemainUnchanged() throws {
        for value in ["", "us-west1", "a b", "a\tb", "=?BASE64?literal?=", "=?base64?unfinished"] {
            XCTAssertEqual(try MCPHTTPHeaderProjection.encodedValue(value), value)
        }
    }

    func testUnsafeStringsAndLiteralSentinelsUseReversibleBase64() throws {
        for value in ["Hello, 世界", " padded ", "\tstart", "end\t", "line1\r\nInjected: yes",
                      "\u{0}", "\u{7F}", "=?base64?literal?=", "=?base64??="] {
            let encoded = try MCPHTTPHeaderProjection.encodedValue(value)
            XCTAssertTrue(encoded.hasPrefix("=?base64?"))
            XCTAssertTrue(encoded.hasSuffix("?="))
            XCTAssertTrue(encoded.utf8.allSatisfy { (33...126).contains($0) })
            let payload = String(encoded.dropFirst(9).dropLast(2))
            XCTAssertEqual(Data(base64Encoded: payload), Data(value.utf8))
        }
        XCTAssertEqual(
            try MCPHTTPHeaderProjection.encodedValue("Hello, 世界"),
            "=?base64?SGVsbG8sIOS4lueVjA==?="
        )
    }

    func testHeaderInjectionInArgumentIsEncodedWithoutLeakingToAnotherField() throws {
        let descriptor = tool(properties: ["text": parameter("string", "Text")])
        let value = "value\r\nAuthorization: injected"
        let headers = try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["text": .string(value)])
        XCTAssertEqual(headers.count, 1)
        XCTAssertEqual(headers["Mcp-Param-Text"], "=?base64?\(Data(value.utf8).base64EncodedString())?=")
        XCTAssertNil(headers["Authorization"])
    }

    func testAllHTTPTokenPunctuationIsAccepted() throws {
        let name = "AZaz09!#$%&'*+-.^_`|~"
        let descriptor = tool(properties: ["value": parameter("string", name)])
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["value": .string("ok")]), [
            "Mcp-Param-\(name)": "ok"
        ])
    }

    func testInvalidHeaderNamesAreRejectedBeforeExtraction() {
        for name in ["", "two words", "\r\nInjected", "Name:Value", "中文", "bad\u{0}", "bad\u{7F}",
                     "with/tab", "quote\"", String(repeating: "A", count: 129)] {
            let descriptor = tool(properties: ["value": parameter("string", name)])
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: descriptor), name.debugDescription)
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [:]))
        }
    }

    func testDuplicateNamesAreCaseInsensitiveAcrossNestedPaths() {
        let descriptor = tool(properties: [
            "first": parameter("string", "Region"),
            "nested": .objectSchema(properties: ["second": parameter("integer", "rEGION")])
        ])
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: descriptor))
    }

    func testAnnotationTypeMustBeNonNullableSupportedPrimitive() {
        for type in [JSONValue.string("number"), .string("object"), .string("array"), .string("null"),
                     .array([.string("string"), .string("null")]), .null] {
            let descriptor = tool(properties: ["value": .object(["type": type, "x-mcp-header": .string("Value")])])
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: descriptor))
        }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(properties: [
            "value": .object(["x-mcp-header": .string("Value")])
        ])))
        for annotation in [JSONValue.bool(true), .number(1), .null, .array([]), .object([:])] {
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(properties: [
                "value": .object(["type": .string("string"), "x-mcp-header": annotation])
            ])))
        }
    }

    func testSafeIntegerBoundariesUseDecimalWithoutExponent() throws {
        let descriptor = tool(properties: ["value": parameter("integer", "Value")])
        for (number, expected) in [(0.0, "0"), (-0.0, "0"), (9_007_199_254_740_991.0, "9007199254740991"),
                                   (-9_007_199_254_740_991.0, "-9007199254740991")] {
            XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["value": .number(number)]), [
                "Mcp-Param-Value": expected
            ])
        }
    }

    func testUnsafeIntegerAndMismatchedArgumentTypesFailClosed() {
        let integer = tool(properties: ["value": parameter("integer", "Value")])
        for value in [JSONValue.number(9_007_199_254_740_992), .number(-9_007_199_254_740_992),
                      .number(.infinity), .number(-.infinity), .number(.nan), .number(1.5),
                      .string("42"), .bool(true), .array([]), .object([:])] {
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(for: integer, arguments: ["value": value]))
        }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(
            for: tool(properties: ["value": parameter("string", "Value")]), arguments: ["value": .bool(true)]
        ))
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(
            for: tool(properties: ["value": parameter("boolean", "Value")]), arguments: ["value": .number(1)]
        ))
    }

    func testAnnotationAtRootOrThroughNonPropertiesKeywordsIsInvalid() {
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: parameter("string", "Root"))))
        let maps = ["patternProperties", "$defs", "definitions", "dependentSchemas", "dependencies"]
        let arrays = ["oneOf", "anyOf", "allOf", "prefixItems"]
        for keyword in maps + arrays + ["items", "additionalProperties", "not", "if", "then", "else",
                                         "contains", "unevaluatedProperties", "unevaluatedItems", "propertyNames",
                                         "additionalItems", "contentSchema"] {
            let annotation = parameter("string", "Invalid")
            let nested: JSONValue = arrays.contains(keyword) ? .array([annotation])
                : maps.contains(keyword) ? .object(["nested": annotation]) : annotation
            XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: .object([
                "type": .string("object"), keyword: nested
            ]))), keyword)
        }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: .object([
            "type": .string("object"),
            "$defs": .object(["referenced": parameter("string", "Invalid")]),
            "properties": .object(["value": .object(["$ref": .string("#/$defs/referenced")])])
        ]))))
    }

    func testUnrelatedReferenceAndConditionalSiblingsDoNotChangeStaticPropertiesPath() throws {
        let siblings: [String: JSONValue] = [
            "$ref": .string("#/$defs/base"),
            "$dynamicRef": .string("#base"),
            "$recursiveRef": .string("#"),
            "allOf": .array([.object(["required": .array([.string("value")])])]),
            "if": .object(["required": .array([.string("optional")])]),
            "items": .bool(false)
        ]
        for (keyword, sibling) in siblings {
            let descriptor = tool(schema: .object([
                "type": .string("object"),
                "properties": .object(["value": parameter("string", "Value")]),
                "$defs": .object(["base": .object(["type": .string("object")])]),
                keyword: sibling
            ]))
            XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["value": .string("ok")]), [
                "Mcp-Param-Value": "ok"
            ], keyword)
        }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: .object([
            "type": .string("array"), "properties": .object(["value": parameter("string", "Value")])
        ]))))
    }

    func testLiteralDataAndSchemaMapNamesAreNotHeaderAnnotations() throws {
        let literal = parameter("string", "Literal Data")
        for (keyword, value) in ["default": literal, "const": literal, "examples": .array([literal]),
                                  "enum": .array([literal]), "x-custom-metadata": literal] {
            let descriptor = tool(schema: .object([
                "type": .string("object"),
                "properties": .object(["value": parameter("string", "Value")]),
                keyword: value
            ]))
            XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["value": .string("ok")]), [
                "Mcp-Param-Value": "ok"
            ], keyword)
        }
        for keyword in ["$defs", "definitions", "patternProperties", "dependentSchemas"] {
            let descriptor = tool(schema: .object([
                "type": .string("object"),
                keyword: .object(["x-mcp-header": .object(["type": .string("string")])])
            ]))
            XCTAssertNoThrow(try MCPHTTPHeaderProjection.validate(tool: descriptor), keyword)
        }
    }

    func testNullableParentObjectPreservesExactNestedProjection() throws {
        let descriptor = tool(properties: ["nested": .object([
            "type": .array([.string("object"), .string("null")]),
            "properties": .object(["value": parameter("string", "Value")])
        ])])
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: [
            "nested": .object(["value": .string("ok")])
        ]), ["Mcp-Param-Value": "ok"])
        XCTAssertEqual(try MCPHTTPHeaderProjection.headers(for: descriptor, arguments: ["nested": .null]), [:])
    }

    func testValueAndAggregateHeaderBudgets() throws {
        XCTAssertEqual(try MCPHTTPHeaderProjection.encodedValue(String(repeating: "x", count: 8_192)).count, 8_192)
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.encodedValue(String(repeating: "x", count: 8_193)))
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.encodedValue(String(repeating: "界", count: 2_731)))
        var properties: [String: JSONValue] = [:]
        var arguments: [String: JSONValue] = [:]
        for index in 0..<4 {
            properties["v\(index)"] = parameter("string", "V\(index)")
            arguments["v\(index)"] = .string(String(repeating: "x", count: 8_192))
        }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(for: tool(properties: properties), arguments: arguments))
    }

    func testHeaderCountAndSchemaBudgetsAreBounded() {
        var properties: [String: JSONValue] = [:]
        for index in 0..<65 { properties["v\(index)"] = parameter("string", "V\(index)") }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(properties: properties)))
        var nested = parameter("string", "Deep")
        for _ in 0..<40 { nested = .objectSchema(properties: ["child": nested]) }
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: nested)))
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: .object([
            "description": .string(String(repeating: "x", count: 512 * 1_024 + 1))
        ]))))
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.validate(tool: tool(schema: .object([
            "enum": .array(Array(repeating: .null, count: 8_193))
        ]))))
    }

    func testProjectionErrorsDoNotEchoSensitiveArguments() {
        let secret = "example-sensitive-value-\(String(repeating: "x", count: 8_193))"
        XCTAssertThrowsError(try MCPHTTPHeaderProjection.headers(
            for: tool(properties: ["value": parameter("string", "Value")]), arguments: ["value": .string(secret)]
        )) { error in
            XCTAssertFalse(error.localizedDescription.contains("example-sensitive-value"))
        }
    }

    private func parameter(_ type: String, _ header: String) -> JSONValue {
        .object(["type": .string(type), "x-mcp-header": .string(header)])
    }

    private func tool(properties: [String: JSONValue]) -> MCPToolDescriptor {
        tool(schema: .objectSchema(properties: properties))
    }

    private func tool(schema: JSONValue) -> MCPToolDescriptor {
        MCPToolDescriptor(name: "header_projection", inputSchema: schema)
    }
}
