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
    public var reasoningDetails: [ReasoningDetail]
    public var toolCalls: [ToolCall]
    public var refusal: String?

    public init(
        content: String = "",
        reasoning: String = "",
        reasoningDetails: [ReasoningDetail] = [],
        toolCalls: [ToolCall] = [],
        refusal: String? = nil
    ) {
        self.content = content
        self.reasoning = reasoning
        self.reasoningDetails = reasoningDetails
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
            reasoningDetails: AssistantTurnContent.mergeReasoningDetails(
                existing: [],
                incoming: reasoningDetails,
                fallback: reasoning
            ),
            toolCalls: toolCalls ?? [],
            refusal: nil
        )
    }
}

public extension ChatCompletionChunk.Choice.Delta {
    /// A merged assistant representation for streaming deltas.
    var assistantTurn: AssistantTurnContent {
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let reasoning = (reasoningContent ?? reasoning ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoningDetails = AssistantTurnContent.mergeReasoningDetails(
            existing: [],
            incoming: reasoningDetails,
            fallback: reasoning
        )
        return AssistantTurnContent(
            content: content,
            reasoning: reasoning,
            reasoningDetails: reasoningDetails,
            toolCalls: AssistantTurnContent.normalizeToolCalls(from: toolCalls)
        )
    }
}

public extension AssistantTurnContent {
    /// Merges reasoning details while also synthesizing a text detail if only
    /// raw reasoning text is available.
    static func mergeReasoningDetails(
        existing: [ReasoningDetail],
        incoming: [ReasoningDetail]?,
        fallback: String?
    ) -> [ReasoningDetail] {
        var result = existing
        if let incoming {
            for detail in incoming {
                if let index = result.firstIndex(where: { $0.matchesContinuation(of: detail) }) {
                    var merged = result[index]
                    merged.merge(with: detail)
                    result[index] = merged
                } else {
                    result.append(detail)
                }
            }
        }
        let hasTextualDetail = result.contains { !($0.text?.isEmpty ?? true) }
        if !hasTextualDetail, let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
            result.append(ReasoningDetail(type: "reasoning.text", text: fallback, format: nil, index: (result.last?.index ?? -1) + 1))
        }
        return result
    }

    static func normalizeToolCalls(
        from deltaCalls: [ChatCompletionChunk.Choice.Delta.ToolCall]?
    ) -> [ToolCall] {
        guard let deltaCalls else { return [] }
        var result: [ToolCall] = []
        for call in deltaCalls {
            guard
                let id = call.id,
                let type = call.type,
                let function = call.function,
                let name = function.name,
                let arguments = function.arguments
            else { continue }

            result.append(ToolCall(
                id: id,
                type: type,
                function: .init(name: name, argumentsJSON: arguments)
            ))
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
