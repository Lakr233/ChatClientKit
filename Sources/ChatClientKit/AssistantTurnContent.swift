//
//  AssistantTurnContent.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/11.
//

import Foundation

/// A unified view of an assistant turn, combining visible content, reasoning,
/// and tool calls.
public struct AssistantTurnContent: Sendable, Equatable {
    public var content: String
    public var reasoning: String
    public var toolCalls: [ToolCall]
    public var refusal: String?

    public init(
        content: String = "",
        reasoning: String = "",
        toolCalls: [ToolCall] = [],
        refusal: String? = nil,
    ) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.refusal = refusal
    }
}

public extension ChoiceMessage {
    /// A merged assistant representation that preserves reasoning details.
    var assistantTurn: AssistantTurnContent {
        AssistantTurnContent(
            content: content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            reasoning: (reasoningContent ?? reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: toolCalls ?? [],
            refusal: nil,
        )
    }
}

public extension ChatCompletionChunk.Choice.Delta {
    /// A merged assistant representation for streaming deltas.
    var assistantTurn: AssistantTurnContent {
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reasoning = (reasoningContent ?? reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return AssistantTurnContent(
            content: content,
            reasoning: reasoning,
            toolCalls: AssistantTurnContent.normalizeToolCalls(from: toolCalls),
        )
    }
}

public extension AssistantTurnContent {
    static func normalizeToolCalls(
        from deltaCalls: [ChatCompletionChunk.Choice.Delta.ToolCall]?,
    ) -> [ToolCall] {
        guard let deltaCalls else { return [] }
        var result: [ToolCall] = []
        for call in deltaCalls {
            guard
                let id = call.id,
                let function = call.function,
                let name = function.name,
                let arguments = function.arguments
            else { continue }

            result.append(ToolCall(id: id, functionName: name, argumentsJSON: arguments))
        }
        return result
    }
}

private extension ToolCallRequest {
    init?(from delta: ChatCompletionChunk.Choice.Delta.ToolCall) {
        guard
            let name = delta.function?.name,
            let args = delta.function?.arguments
        else { return nil }
        self.init(name: name, args: args)
    }
}
