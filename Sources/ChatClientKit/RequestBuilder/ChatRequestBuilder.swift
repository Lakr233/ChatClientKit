//
//  ChatRequestBuilder.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

@resultBuilder
public enum ChatRequestBuilder {
    public static func buildBlock(
        _ components: [ChatRequest.BuildComponent]...
    ) -> [ChatRequest.BuildComponent] {
        components.flatMap(\.self)
    }

    public static func buildExpression(
        _ expression: @escaping ChatRequest.BuildComponent
    ) -> [ChatRequest.BuildComponent] {
        [expression]
    }

    public static func buildExpression(
        _ expression: [ChatRequest.BuildComponent]
    ) -> [ChatRequest.BuildComponent] {
        expression
    }

    public static func buildOptional(
        _ component: [ChatRequest.BuildComponent]?
    ) -> [ChatRequest.BuildComponent] {
        component ?? []
    }

    public static func buildEither(
        first component: [ChatRequest.BuildComponent]
    ) -> [ChatRequest.BuildComponent] {
        component
    }

    public static func buildEither(
        second component: [ChatRequest.BuildComponent]
    ) -> [ChatRequest.BuildComponent] {
        component
    }

    public static func buildArray(
        _ components: [[ChatRequest.BuildComponent]]
    ) -> [ChatRequest.BuildComponent] {
        components.flatMap(\.self)
    }

    public static func buildLimitedAvailability(
        _ component: [ChatRequest.BuildComponent]
    ) -> [ChatRequest.BuildComponent] {
        component
    }
}

public extension ChatRequest {
    typealias BuildComponent = @Sendable (inout ChatRequest) -> Void

    init(@ChatRequestBuilder _ content: @Sendable () -> [BuildComponent]) {
        self.init(messages: [])
        apply(content())
    }

    mutating func apply(_ components: [BuildComponent]) {
        for component in components {
            component(&self)
        }
    }
}

// MARK: - Request Modifiers

public extension ChatRequest {
    static func model(_ value: String) -> BuildComponent {
        { $0.model = value }
    }

    static func messages(
        @ChatMessageBuilder _ builder: @Sendable @escaping () -> [Message]
    ) -> BuildComponent {
        { request in
            request.messages = builder()
        }
    }

    static func appendMessages(
        @ChatMessageBuilder _ builder: @Sendable @escaping () -> [Message]
    ) -> BuildComponent {
        { request in
            request.messages.append(contentsOf: builder())
        }
    }

    static func message(_ message: Message) -> BuildComponent {
        { request in
            request.messages.append(message)
        }
    }

    static func maxCompletionTokens(_ value: Int?) -> BuildComponent {
        { $0.maxCompletionTokens = value }
    }

    static func stream(_ value: Bool?) -> BuildComponent {
        { $0.stream = value }
    }

    static func temperature(_ value: Double?) -> BuildComponent {
        { $0.temperature = value }
    }

    static func tools(_ value: [Tool]?) -> BuildComponent {
        { $0.tools = value }
    }
}

// MARK: - Message Shortcuts

public extension ChatRequest {
    static func system(
        _ text: String,
        name: String? = nil
    ) -> BuildComponent {
        message(.system(content: .text(text), name: name))
    }

    static func developer(
        _ text: String,
        name: String? = nil
    ) -> BuildComponent {
        message(.developer(content: .text(text), name: name))
    }

    static func assistant(
        _ text: String,
        name: String? = nil
    ) -> BuildComponent {
        message(.assistant(content: .text(text), name: name))
    }

    static func assistant(
        content: MessageContent<String, [String]>?,
        name: String? = nil,
        refusal: String? = nil,
        toolCalls: [Message.ToolCall]? = nil
    ) -> BuildComponent {
        message(.assistant(
            content: content,
            name: name,
            refusal: refusal,
            toolCalls: toolCalls
        ))
    }

    static func user(
        _ text: String,
        name: String? = nil
    ) -> BuildComponent {
        message(.user(content: .text(text), name: name))
    }

    static func user(
        parts: [ContentPart],
        name: String? = nil
    ) -> BuildComponent {
        message(.user(content: .parts(parts), name: name))
    }

    static func tool(
        _ content: MessageContent<String, [String]>,
        toolCallID: String
    ) -> BuildComponent {
        message(.tool(content: content, toolCallID: toolCallID))
    }
}
