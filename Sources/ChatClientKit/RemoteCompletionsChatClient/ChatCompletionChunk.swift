import Foundation

/// Streamed chunk of a chat completion response.
public struct ChatCompletionChunk: Sendable, Decodable {
    public var choices: [Choice]
}

public extension ChatCompletionChunk {
    struct Choice: Sendable, Decodable {
        public let delta: Delta

        /// Reason the model stopped generating tokens.
        public let finishReason: String?

        public let index: Int?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
            case index
        }

        public init(delta: Delta, finishReason: String? = nil, index: Int? = nil) {
            self.delta = delta
            self.finishReason = finishReason
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
        public let images: [CompletionImageCollector]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoning
            case reasoningContent = "reasoning_content"
            case role
            case toolCalls = "tool_calls"
            case images = "image"
        }

        public init(
            content: String? = nil,
            reasoning: String? = nil,
            reasoningContent: String? = nil,
            role: String? = nil,
            toolCalls: [ToolCall]? = nil,
            images: [CompletionImageCollector]? = nil,
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
    }
}

public extension ChatCompletionChunk.Choice.Delta.ToolCall {
    struct Function: Sendable, Decodable {
        public let name: String?

        public let arguments: String?
    }
}
