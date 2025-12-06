import CryptoKit
import Foundation

/// Domain representation of a chat completion request, mirroring `ChatRequestBody`
/// with builder conveniences, normalization, and caching helpers.
public struct ChatRequest: Sendable {
    public var model: String?
    public var messages: [Message]
    public var maxCompletionTokens: Int?
    public var stream: Bool?
    public var temperature: Double?
    public var tools: [Tool]?

    public init(
        model: String? = nil,
        messages: [Message],
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

    public init(
        model: String? = nil,
        maxCompletionTokens: Int? = nil,
        stream: Bool? = nil,
        temperature: Double? = nil,
        tools: [Tool]? = nil,
        @ChatMessageBuilder messages: @Sendable () -> [Message],
    ) {
        self.init(
            model: model,
            messages: messages(),
            maxCompletionTokens: maxCompletionTokens,
            stream: stream,
            temperature: temperature,
            tools: tools,
        )
    }

    public var cacheIdentifier: CacheIdentifier {
        CacheIdentifier(request: self)
    }
}

extension ChatRequest: ChatRequestConvertible {
    public func asChatRequestBody() throws -> ChatRequestBody {
        var body = ChatRequestBody(
            messages: Self.normalize(messages),
            maxCompletionTokens: maxCompletionTokens,
            stream: stream,
            temperature: temperature,
            tools: tools.map(Self.normalizeTools),
        )
        body.model = Self.trimmed(model)
        return body
    }
}

// MARK: - Cache Identifier

public extension ChatRequest {
    struct CacheIdentifier: Sendable, Hashable {
        public let rawValue: String

        init(request: ChatRequest) {
            do {
                let canonical = try request.asChatRequestBody()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(canonical)
                let digest = SHA256.hash(data: data)
                rawValue = digest.map { String(format: "%02x", $0) }.joined()
            } catch {
                rawValue = ""
            }
        }
    }
}

// MARK: - Normalization Helpers

extension ChatRequest {
    static func normalize(_ messages: [Message]) -> [Message] {
        mergeAssistantMessages(messages).map(normalizeMessage)
    }

    static func normalizeMessage(_ message: Message) -> Message {
        switch message {
        case let .assistant(content, toolCalls, reasoning):
            .assistant(
                content: normalizeAssistantContent(content),
                toolCalls: normalizeToolCalls(toolCalls),
                reasoning: trimmed(reasoning),
            )
        case let .developer(content, name):
            .developer(content: normalizeTextContent(content), name: trimmed(name))
        case let .system(content, name):
            .system(content: normalizeTextContent(content), name: trimmed(name))
        case let .tool(content, toolCallID):
            .tool(content: normalizeTextContent(content), toolCallID: trimmed(toolCallID) ?? toolCallID)
        case let .user(content, name):
            .user(content: normalizeUserContent(content), name: trimmed(name))
        }
    }

    static func normalizeAssistantContent(
        _ content: MessageContent<String, [String]>?,
    ) -> MessageContent<String, [String]>? {
        guard let content else { return nil }
        switch content {
        case let .text(text):
            guard let normalized = trimmed(text), !normalized.isEmpty else { return nil }
            return .text(normalized)
        case let .parts(parts):
            let normalized = parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized.isEmpty ? nil : .parts(normalized)
        }
    }

    static func normalizeTextContent(
        _ content: MessageContent<String, [String]>,
    ) -> MessageContent<String, [String]> {
        switch content {
        case let .text(text):
            return .text(trimmed(text) ?? "")
        case let .parts(parts):
            let normalized = parts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return normalized.isEmpty ? .parts([]) : .parts(normalized)
        }
    }

    static func normalizeUserContent(
        _ content: MessageContent<String, [ContentPart]>,
    ) -> MessageContent<String, [ContentPart]> {
        switch content {
        case let .text(text):
            return .text(trimmed(text) ?? "")
        case let .parts(parts):
            let normalized = parts.compactMap(normalizeContentPart)
            return .parts(normalized)
        }
    }

    static func normalizeContentPart(_ part: ContentPart) -> ContentPart? {
        switch part {
        case let .text(text):
            guard let normalized = trimmed(text), !normalized.isEmpty else { return nil }
            return .text(normalized)
        case let .imageURL(url, detail):
            return .imageURL(url, detail: detail)
        case let .audioBase64(data, format):
            guard let normalized = trimmed(data), !normalized.isEmpty else { return nil }
            return .audioBase64(normalized, format: format)
        }
    }

    static func normalizeToolCalls(
        _ toolCalls: [Message.ToolCall]?,
    ) -> [Message.ToolCall]? {
        guard let toolCalls, !toolCalls.isEmpty else { return nil }
        let normalized = toolCalls.map { call in
            Message.ToolCall(
                id: trimmed(call.id) ?? call.id,
                function: .init(
                    name: trimmed(call.function.name) ?? call.function.name,
                    arguments: trimmed(call.function.arguments),
                ),
            )
        }
        return normalized.sorted { $0.id < $1.id }
    }

    static func normalizeTools(_ tools: [Tool]) -> [Tool] {
        tools.sorted(by: toolSortKey).map(normalizeTool)
    }

    static func normalizeTool(_ tool: Tool) -> Tool {
        switch tool {
        case let .function(name, description, parameters, strict):
            .function(
                name: trimmed(name) ?? name,
                description: trimmed(description),
                parameters: parameters,
                strict: strict,
            )
        }
    }

    static func toolSortKey(lhs: Tool, rhs: Tool) -> Bool {
        switch (lhs, rhs) {
        case let (.function(lhsName, _, _, _), .function(rhsName, _, _, _)):
            lhsName < rhsName
        }
    }

    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func trimmed(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Merge adjacent assistant messages so the upstream API receives a single, coherent turn.
    static func mergeAssistantMessages(_ messages: [Message]) -> [Message] {
        var result: [Message] = []
        var pending: PendingAssistant?

        func flushPending() {
            guard let assistant = pending else { return }
            result.append(assistant.asMessage())
            pending = nil
        }

        for message in messages {
            switch message {
            case let .assistant(content, toolCalls, reasoning):
                if var current = pending {
                    current.append(content: content)
                    current.append(reasoning: reasoning)
                    current.append(toolCalls: toolCalls)
                    pending = current
                } else {
                    pending = PendingAssistant(
                        content: content,
                        toolCalls: toolCalls,
                        reasoning: reasoning,
                    )
                }
            default:
                flushPending()
                result.append(message)
            }
        }

        flushPending()
        return result
    }
}

struct PendingAssistant {
    var content: ChatRequest.Message.MessageContent<String, [String]>?
    var toolCalls: [ChatRequest.Message.ToolCall]?
    var reasoning: String?

    mutating func append(content newContent: ChatRequest.Message.MessageContent<String, [String]>?) {
        guard let newContent else { return }
        switch (content, newContent) {
        case let (.text(lhs)?, .text(rhs)):
            let separator = lhs.isEmpty || rhs.isEmpty ? "" : "\n\n"
            content = .text(lhs + separator + rhs)
        case let (.parts(lhs)?, .parts(rhs)):
            content = .parts(lhs + rhs)
        case (.text, .parts), (.parts, .text):
            let lhsText: String = switch content {
            case let .text(text)?: text
            case let .parts(parts)?: parts.joined(separator: "\n")
            case .none: ""
            }
            switch newContent {
            case let .text(text): content = .text([lhsText, text].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            case let .parts(parts):
                let combined = [lhsText, parts.joined(separator: "\n")].filter { !$0.isEmpty }
                content = .text(combined.joined(separator: "\n\n"))
            }
        case (nil, _):
            content = newContent
        }
    }

    mutating func append(reasoning newReasoning: String?) {
        if let incoming = newReasoning, !(incoming.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            if let existing = reasoning {
                let separator = existing.isEmpty || incoming.isEmpty ? "" : "\n"
                reasoning = existing + separator + incoming
            } else {
                reasoning = incoming
            }
        }
    }

    mutating func append(toolCalls newCalls: [ChatRequest.Message.ToolCall]?) {
        guard let newCalls, !newCalls.isEmpty else { return }
        toolCalls = (toolCalls ?? []) + newCalls
    }

    func asMessage() -> ChatRequest.Message {
        .assistant(
            content: content,
            toolCalls: toolCalls,
            reasoning: reasoning,
        )
    }
}
