@testable import ChatClientKit
import Foundation
import FoundationModels
import Testing

/// A web search tool's parameters as MCP servers send them: optional
/// arguments typed `[X, "null"]`, the shape that made every Apple
/// Intelligence request with tools fail before streaming.
private let webSearchParameters: [String: AnyCodingValue] = [
    "type": "object",
    "properties": [
        "query": ["type": "string", "description": "Search query"],
        "include_favicon": [
            "type": ["boolean", "null"],
            "description": "Include the favicon URL of each result",
            "default": false,
        ],
        "max_results": ["type": ["integer", "null"], "default": 5],
    ],
    "required": ["query", "include_favicon"],
]

struct AppleIntelligenceJSONSchemaSanitizerTests {
    private func sanitize(_ json: String) throws -> [String: Any] {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        return AppleIntelligenceJSONSchemaSanitizer.sanitize(object)
    }

    private func property(_ schema: [String: Any], _ name: String) -> [String: Any] {
        (schema["properties"] as? [String: Any])?[name] as? [String: Any] ?? [:]
    }

    @Test
    func `Type array with null becomes the single type and the property optional`() throws {
        let schema = try sanitize(#"""
        {"type":"object","properties":{"a":{"type":["string","null"]},"b":{"type":"string"}},"required":["a","b"]}
        """#)

        #expect(property(schema, "a")["type"] as? String == "string")
        #expect(schema["required"] as? [String] == ["b"])
    }

    @Test
    func `Boolean or null like include_favicon becomes an optional boolean`() throws {
        let schema = AppleIntelligenceJSONSchemaSanitizer.sanitize(webSearchParameters.untypedDictionary)

        let favicon = property(schema, "include_favicon")
        #expect(favicon["type"] as? String == "boolean")
        #expect(favicon["description"] as? String == "Include the favicon URL of each result")
        #expect(property(schema, "max_results")["type"] as? String == "integer")
        #expect(schema["required"] as? [String] == ["query"])
    }

    @Test
    func `Several non-null types keep the first`() throws {
        let schema = try sanitize(#"""
        {"type":"object","properties":{"v":{"type":["number","string"]}},"required":["v"]}
        """#)

        #expect(property(schema, "v")["type"] as? String == "number")
        #expect(schema["required"] as? [String] == ["v"])
    }

    @Test
    func `Nested objects and array items are sanitized`() throws {
        let schema = try sanitize(#"""
        {"type":"object","properties":{
          "filters":{"type":["object","null"],"properties":{
            "tags":{"type":"array","items":{"type":["string","null"]}},
            "site":{"type":["string","null"]}
          },"required":["tags","site"]}
        },"required":["filters"]}
        """#)

        let filters = property(schema, "filters")
        #expect(filters["type"] as? String == "object")
        #expect(filters["required"] as? [String] == ["tags"])
        #expect(schema["required"] as? [String] == [])
        let tags = (filters["properties"] as? [String: Any])?["tags"] as? [String: Any]
        let items = tags?["items"] as? [String: Any]
        #expect(items?["type"] as? String == "string")
    }

    @Test
    func `Nullable anyOf collapses to the other branch`() throws {
        let schema = try sanitize(#"""
        {"type":"object","properties":{
          "limit":{"anyOf":[{"type":"integer","minimum":1},{"type":"null"}],"description":"Max"},
          "mode":{"oneOf":[{"type":"null"},{"type":"string","enum":["fast","slow"]}]}
        },"required":["limit","mode"]}
        """#)

        let limit = property(schema, "limit")
        #expect(limit["anyOf"] == nil)
        #expect(limit["type"] as? String == "integer")
        #expect(limit["description"] as? String == "Max")
        let mode = property(schema, "mode")
        #expect(mode["oneOf"] == nil)
        #expect(mode["enum"] as? [String] == ["fast", "slow"])
        #expect(schema["required"] as? [String] == [])
    }

    @Test
    func `Missing type is inferred and unknown required names are dropped`() throws {
        let schema = try sanitize(#"""
        {"properties":{"q":{"type":"string"}},"required":["q","ghost"],"$schema":"https://json-schema.org/draft/2020-12/schema"}
        """#)

        #expect(schema["type"] as? String == "object")
        #expect(schema["required"] as? [String] == ["q"])
        #expect(schema["$schema"] == nil)
    }
}

struct AppleIntelligenceToolSchemaDecodingTests {
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    private func encodedObject(_ schema: GenerationSchema) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(schema)) as? [String: Any]
        )
    }

    /// Finds the object schema that lists `property`, wherever the encoder put it.
    private func objectSchema(listing property: String, in value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            if let properties = object["properties"] as? [String: Any], properties[property] != nil {
                return object
            }
            for child in object.values {
                if let found = objectSchema(listing: property, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = objectSchema(listing: property, in: child) { return found }
            }
        }
        return nil
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `GenerationSchema rejects a raw type array, the reported failure`() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "object",
            "title": "ToolArguments",
            "properties": ["include_favicon": ["type": ["boolean", "null"]]],
            "x-order": ["include_favicon"],
            "required": [String](),
            "additionalProperties": false,
        ] as [String: Any])

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(GenerationSchema.self, from: data)
        }
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Tool with include_favicon boolean or null now decodes`() throws {
        let proxy = try AppleIntelligenceToolProxy(
            name: "web_search",
            description: "Search the web",
            parameters: webSearchParameters
        )

        let encoded = try encodedObject(proxy.parameters)
        let object = try #require(objectSchema(listing: "include_favicon", in: encoded))
        #expect(object["required"] as? [String] == ["query"])
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Nested nullable objects, items and anyOf decode`() throws {
        let parameters = try JSONDecoder().decode([String: AnyCodingValue].self, from: Data(#"""
        {"type":"object","properties":{
          "filters":{"type":["object","null"],"description":"Filters","properties":{
            "tags":{"type":"array","items":{"type":["string","null"]}},
            "limit":{"anyOf":[{"type":"integer"},{"type":"null"}]},
            "mode":{"type":"string","enum":["fast","slow"]}
          },"required":["tags"]},
          "urls":{"type":["array","null"],"items":{"type":"string"}}
        },"required":["filters"]}
        """#.utf8))

        let proxy = try AppleIntelligenceToolProxy(
            name: "nested",
            description: nil,
            parameters: parameters
        )

        let encoded = try encodedObject(proxy.parameters)
        #expect(objectSchema(listing: "tags", in: encoded) != nil)
        #expect(objectSchema(listing: "urls", in: encoded) != nil)
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Common annotation keywords decode`() throws {
        let parameters = try JSONDecoder().decode([String: AnyCodingValue].self, from: Data(#"""
        {"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{
          "url":{"type":"string","format":"uri","default":"https://example.com","examples":["https://a.b"]},
          "depth":{"type":"integer","minimum":0,"maximum":3,"default":1},
          "ratio":{"type":"number","exclusiveMinimum":0},
          "tags":{"type":"array","items":{"type":"string"},"minItems":0,"maxItems":5}
        },"required":["url"],"additionalProperties":false}
        """#.utf8))

        _ = try AppleIntelligenceToolProxy(name: "annotated", description: nil, parameters: parameters)
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `A tool whose schema still fails is skipped and the rest survive`() throws {
        let tools: [ChatRequestBody.Tool] = [
            .function(name: "web_search", description: nil, parameters: webSearchParameters, strict: nil),
            .function(name: "broken", description: nil, parameters: ["type": 42], strict: nil),
            .function(name: "noop", description: nil, parameters: nil, strict: nil),
        ]

        let conversion = try AppleIntelligenceToolProxy.makeProxies(from: tools, toolChoice: .auto)

        #expect(conversion.tools.map(\.name) == ["web_search", "noop"])
        #expect(conversion.skipped.map(\.name) == ["broken"])
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `A forced tool that can't be converted still fails the request`() {
        let tools: [ChatRequestBody.Tool] = [
            .function(name: "broken", description: nil, parameters: ["type": 42], strict: nil),
        ]

        #expect(throws: DecodingError.self) {
            _ = try AppleIntelligenceToolProxy.makeProxies(
                from: tools,
                toolChoice: .function(name: "broken")
            )
        }
    }

    @Test
    @available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *)
    func `On-device session is created when one tool is unusable`() throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [.user(content: .text("Search the web"))],
            tools: [
                .function(name: "web_search", description: nil, parameters: webSearchParameters, strict: nil),
                .function(name: "broken", description: nil, parameters: ["type": 42], strict: nil),
            ]
        )

        let context = try client.makeSessionContext(body: body, persona: "")

        #expect(context.prompt == "Search the web")
    }
}

#if compiler(>=6.4)
    struct PrivateCloudComputeToolSkippingTests {
        @Test
        @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
        func `Cloud session counts passed and skipped tools`() throws {
            let client = PrivateCloudComputeChatClient()
            let body = ChatRequestBody(
                messages: [.user(content: .text("Search the web"))],
                tools: [
                    .function(name: "web_search", description: nil, parameters: webSearchParameters, strict: nil),
                    .function(name: "broken", description: nil, parameters: ["type": 42], strict: nil),
                ]
            )

            let context = try client.makeSessionContext(body: body)

            #expect(context.tools == 1)
            #expect(context.skippedTools == ["broken"])
        }
    }
#endif
