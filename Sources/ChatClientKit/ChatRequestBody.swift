import Foundation

public struct ChatRequestBody: Sendable, Encodable {
    public var model: String?
    public var messages: [Message]
    public var maxCompletionTokens: Int?
    public var stream: Bool?
    public var temperature: Double?
    public var tools: [Tool]?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxCompletionTokens = "max_completion_tokens"
        case stream
        case temperature
        case tools
    }

    public init(
        model: String? = nil,
        messages: [Message] = [],
        maxCompletionTokens: Int? = nil,
        stream: Bool? = nil,
        temperature: Double? = nil,
        tools: [Tool]? = nil,
    ) {
        self.model = model
        self.messages = messages
        self.maxCompletionTokens = maxCompletionTokens
        self.stream = stream
        self.temperature = temperature
        self.tools = tools
    }
}

public extension ChatRequestBody {
    enum Message: Sendable, Encodable {
        case assistant(
            content: MessageContent<String, [String]>? = nil,
            toolCalls: [ToolCall]? = nil,
            reasoning: String? = nil,
        )

        case developer(
            content: MessageContent<String, [String]>,
            name: String? = nil,
        )

        case system(
            content: MessageContent<String, [String]>,
            name: String? = nil,
        )

        case tool(
            content: MessageContent<String, [String]>,
            toolCallID: String,
        )

        case user(
            content: MessageContent<String, [ContentPart]>,
            name: String? = nil,
        )

        var role: String {
            switch self {
            case .assistant: "assistant"
            case .developer: "developer"
            case .system: "system"
            case .tool: "tool"
            case .user: "user"
            }
        }

        enum RootKey: String, CodingKey, Equatable {
            case content
            case name
            case reasoning
            case role
            case toolCallID = "tool_call_id"
            case toolCalls = "tool_calls"
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: RootKey.self)
            try container.encode(role, forKey: .role)
            switch self {
            case let .assistant(content, toolCalls, reasoning):
                try container.encodeIfPresent(content, forKey: .content)
                try container.encodeIfPresent(reasoning, forKey: .reasoning)
                try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
            case let .developer(content, name):
                try container.encode(content, forKey: .content)
                try container.encodeIfPresent(name, forKey: .name)
            case let .system(content, name):
                try container.encode(content, forKey: .content)
                try container.encodeIfPresent(name, forKey: .name)
            case let .tool(content, toolCallID):
                try container.encode(content, forKey: .content)
                try container.encode(toolCallID, forKey: .toolCallID)
            case let .user(content, name):
                try container.encode(content, forKey: .content)
                try container.encodeIfPresent(name, forKey: .name)
            }
        }
    }
}

public extension ChatRequestBody.Message {
    enum MessageContent<SingleType: Encodable, PartsType: Encodable>: @unchecked Sendable, Encodable, SingleOrPartsEncodable {
        case text(SingleType)
        case parts(PartsType)

        var encodableItem: Encodable {
            switch self {
            case let .text(single):
                single
            case let .parts(parts):
                parts
            }
        }
    }
}

public extension ChatRequestBody.Message {
    enum ContentPart: Sendable, Encodable {
        case text(String)

        /// Data URL image content with optional detail hint.
        case imageURL(URL, detail: ImageDetail? = nil)

        /// Base64 audio payload with format (e.g. "wav").
        case audioBase64(String, format: String)

        enum RootKey: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
            case audio = "input_audio"
        }

        enum ImageKey: CodingKey {
            case url
            case detail
        }

        enum AudioKey: CodingKey {
            case data
            case format
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: RootKey.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .imageURL(url, detail):
                try container.encode("image_url", forKey: .type)
                var nestedContainer = container.nestedContainer(
                    keyedBy: ImageKey.self, forKey: .imageURL,
                )
                try nestedContainer.encode(url, forKey: .url)
                if let detail {
                    try nestedContainer.encode(detail, forKey: .detail)
                }
            case let .audioBase64(data, format):
                try container.encode("input_audio", forKey: .type)
                var nestedContainer = container.nestedContainer(
                    keyedBy: AudioKey.self,
                    forKey: .audio,
                )
                try nestedContainer.encode(data, forKey: .data)
                try nestedContainer.encode(format, forKey: .format)
            }
        }
    }
}

public extension ChatRequestBody.Message.ContentPart {
    enum ImageDetail: String, Sendable, Encodable {
        case auto
        case low
        case high
    }
}

public extension ChatRequestBody.Message {
    struct ToolCall: Sendable, Encodable {
        let id: String
        let type = "function"
        let function: Function

        public init(
            id: String,
            function: ChatRequestBody.Message.ToolCall.Function,
        ) {
            self.id = id
            self.function = function
        }
    }
}

public extension ChatRequestBody.Message.ToolCall {
    struct Function: Sendable, Encodable {
        public let name: String

        public let arguments: String?

        public init(
            name: String,
            arguments: String? = nil,
        ) {
            self.name = name
            self.arguments = arguments
        }
    }
}

public extension ChatRequestBody {
    enum Tool: Sendable, Encodable {
        case function(
            name: String,
            description: String?,
            parameters: [String: AnyCodingValue]?,
            strict: Bool?,
        )

        enum RootKey: CodingKey {
            case type
            case function
        }

        enum FunctionKey: CodingKey {
            case description
            case name
            case parameters
            case strict
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: RootKey.self)
            switch self {
            case let .function(
                name: name,
                description: description,
                parameters: parameters,
                strict: strict,
            ):
                try container.encode("function", forKey: .type)
                var functionContainer = container.nestedContainer(
                    keyedBy: FunctionKey.self,
                    forKey: .function,
                )
                try functionContainer.encode(name, forKey: .name)
                try functionContainer.encodeIfPresent(description, forKey: .description)
                try functionContainer.encodeIfPresent(parameters, forKey: .parameters)
                try functionContainer.encodeIfPresent(strict, forKey: .strict)
            }
        }
    }
}

public extension ChatRequestBody {
    /// Returns a copy where adjacent assistant messages are merged into a single turn.
    func mergingAdjacentAssistantMessages() -> ChatRequestBody {
        var merged = ChatRequestBody(
            messages: ChatRequest.mergeAssistantMessages(messages),
            maxCompletionTokens: maxCompletionTokens,
            stream: stream,
            temperature: temperature,
            tools: tools,
        )
        merged.model = model
        merged.stream = stream
        return merged
    }
}
