import Foundation

/// Streamed chunk of a chat completion response.
public struct ChatCompletionChunk: Sendable, Decodable {
    public var choices: [Choice]
}

public extension ChatCompletionChunk {
    struct Choice: Sendable, Decodable {
        public let delta: Delta

        public let index: Int?

        enum CodingKeys: String, CodingKey {
            case delta
            case index
        }

        public init(delta: Delta, index: Int? = nil) {
            self.delta = delta
            self.index = index
        }
    }
}

public extension ChatCompletionChunk.Choice {
    struct Delta: Sendable, Decodable {
        public let content: String?
        public let reasoning: String?
        public let reasoningContent: String?
        public let role: String?
        public let toolCalls: [ToolCall]?
        public let images: [CompletionImage]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoning
            case reasoningContent = "reasoning_content"
            case role
            case toolCalls = "tool_calls"
            case images
        }

        public init(
            content: String? = nil,
            reasoning: String? = nil,
            reasoningContent: String? = nil,
            role: String? = nil,
            toolCalls: [ToolCall]? = nil,
            images: [CompletionImage]? = nil
        ) {
            self.content = content
            self.reasoning = reasoning
            self.reasoningContent = reasoningContent
            self.role = role
            self.toolCalls = toolCalls
            self.images = images
        }
    }
}

public extension ChatCompletionChunk.Choice.Delta {
    struct ToolCall: Sendable, Decodable {
        public let index: Int?
        public let id: String?
        public let type: String?
        public let function: Function?
        /// Keys beyond `index`, `id`, `type` and `function`, kept verbatim so
        /// they can be echoed back (e.g. Gemini's `extra_content`).
        public let extraFields: [String: AnyCodingValue]?

        public init(
            index: Int? = nil,
            id: String? = nil,
            type: String? = nil,
            function: Function? = nil,
            extraFields: [String: AnyCodingValue]? = nil
        ) {
            self.index = index
            self.id = id
            self.type = type
            self.function = function
            self.extraFields = (extraFields?.isEmpty ?? true) ? nil : extraFields
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: ToolCallFieldKey.self)
            index = try container.decodeIfPresent(Int.self, forKey: .init("index"))
            id = try container.decodeIfPresent(String.self, forKey: .init("id"))
            type = try container.decodeIfPresent(String.self, forKey: .init("type"))
            function = try container.decodeIfPresent(Function.self, forKey: .init("function"))
            var extras: [String: AnyCodingValue] = [:]
            for key in container.allKeys where !ToolCallFieldKey.standardFields.contains(key.stringValue) {
                extras[key.stringValue] = try container.decode(AnyCodingValue.self, forKey: key)
            }
            extraFields = extras.isEmpty ? nil : extras
        }
    }
}

/// Dynamic key for tool-call objects, which may carry provider-specific
/// fields next to the standard OpenAI ones.
struct ToolCallFieldKey: CodingKey {
    static let standardFields: Set<String> = ["index", "id", "type", "function"]

    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) { self.stringValue = stringValue }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue _: Int) { nil }
}

public extension ChatCompletionChunk.Choice.Delta.ToolCall {
    struct Function: Sendable, Decodable {
        public let name: String?
        public let arguments: String?
    }
}
