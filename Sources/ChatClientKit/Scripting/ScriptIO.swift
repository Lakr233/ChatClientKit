//
//  ScriptIO.swift
//  ChatClientKit
//
//  Strong-typed boundary between Swift and JavaScriptCore.
//  All struct-level fields are Codable; the internal `AnyCodingValue`
//  escape hatch is reserved for genuinely free JSON (body / manifest
//  payload).
//

import Foundation

/// Ordered list of headers (name, value) — preserves the order in which
/// the script wants them set on the URLRequest. Wire-order is not
/// guaranteed (see plan §1.6), but the insertion order is the best
/// signal we can pass through `URLRequest.setValue`.
public struct ScriptHeaderList: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }
}

/// Output of a `pre_process` script invocation.
/// The script's `__result` must JSON-stringify into this shape.
public struct PreProcessOutput: Codable, Sendable {
    public var headers: ScriptHeaderList
    public var body: AnyCodingValue

    public init(headers: ScriptHeaderList, body: AnyCodingValue) {
        self.headers = headers
        self.body = body
    }
}

/// Output of a `post_process` script invocation. Any field optional.
public struct PostProcessOutput: Codable, Sendable {
    public struct ToolCall: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var args: String // raw JSON string,与 ToolRequest 对齐

        public init(id: String, name: String, args: String) {
            self.id = id
            self.name = name
            self.args = args
        }
    }

    public var reasoning: String?
    public var content: String?
    public var toolCalls: [ToolCall]?

    public init(
        reasoning: String? = nil,
        content: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) {
        self.reasoning = reasoning
        self.content = content
        self.toolCalls = toolCalls
    }

    enum CodingKeys: String, CodingKey {
        case reasoning, content
        case toolCalls = "tool_calls"
    }
}

/// Snapshot of `ChatRequestBody` injected as the JS global `chatSession`.
/// Includes message bodies in full (including base64 image content).
/// **Frozen** in JS via deepFreeze — scripts can read but not mutate.
public struct ChatSessionSnapshot: Codable, Sendable {
    public var model: String?
    public var messages: [AnyCodingValue]
    public var tools: [AnyCodingValue]?
    public var stream: Bool?
    public var temperature: Double?
    public var maxCompletionTokens: Int?

    public init(
        model: String? = nil,
        messages: [AnyCodingValue] = [],
        tools: [AnyCodingValue]? = nil,
        stream: Bool? = nil,
        temperature: Double? = nil,
        maxCompletionTokens: Int? = nil
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.stream = stream
        self.temperature = temperature
        self.maxCompletionTokens = maxCompletionTokens
    }

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature
        case maxCompletionTokens = "max_completion_tokens"
    }
}

/// Opaque manifest passed to scripts. **No fields are defined here on
/// purpose** — adapter layer (FlowDown app) is responsible for
/// constructing the payload via a whitelist (see plan §1.10 and §8.1).
/// ChatClientKit does not know about CloudModel and cannot redact.
public struct ManifestSnapshot: Codable, Sendable {
    public var payload: AnyCodingValue

    public init(payload: AnyCodingValue) {
        self.payload = payload
    }
}

public extension ChatSessionSnapshot {
    /// Build from a `ChatRequestBody`. Internal helper for the integration
    /// path (used by Pre/Post processors).
    static func make(from body: ChatRequestBody) throws -> ChatSessionSnapshot {
        // Round-trip through Foundation JSON to project ChatRequestBody (Encodable only)
        // into `AnyCodingValue` arrays/objects.
        let data = try JSONEncoder().encode(body)
        struct Wire: Decodable {
            var model: String?
            var messages: [AnyCodingValue]
            var tools: [AnyCodingValue]?
            var stream: Bool?
            var temperature: Double?
            var max_completion_tokens: Int?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        return ChatSessionSnapshot(
            model: wire.model,
            messages: wire.messages,
            tools: wire.tools,
            stream: wire.stream,
            temperature: wire.temperature,
            maxCompletionTokens: wire.max_completion_tokens
        )
    }
}
