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
    public var toolCalls: [ToolRequest]
    public var refusal: String?
    public var images: [ImageContent]

    public init(
        content: String = "",
        reasoning: String = "",
        toolCalls: [ToolRequest] = [],
        refusal: String? = nil,
        images: [ImageContent] = [],
    ) {
        self.content = content
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.refusal = refusal
        self.images = images
    }
}

public extension ChatCompletionChunk.Choice.Delta {
    /// A merged assistant representation for streaming deltas.
    var assistantTurn: AssistantTurnContent {
        let content = content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AssistantTurnContent(
            content: content,
            reasoning: "",
            toolCalls: AssistantTurnContent.normalizeToolCalls(from: toolCalls),
            images: AssistantTurnContent.normalizeImages(from: images),
        )
    }
}

public extension AssistantTurnContent {
    static func normalizeToolCalls(
        from deltaCalls: [ChatCompletionChunk.Choice.Delta.ToolCall]?,
    ) -> [ToolRequest] {
        guard let deltaCalls else { return [] }
        var result: [ToolRequest] = []
        for call in deltaCalls {
            guard
                let id = call.id,
                let function = call.function,
                let name = function.name,
                let arguments = function.arguments
            else { continue }

            result.append(ToolRequest(id: id, name: name, args: arguments))
        }
        return result
    }

    static func normalizeImages(from items: [CompletionImageCollector]?) -> [ImageContent] {
        guard let items else { return [] }
        return items.compactMap { dto in
            guard let urlString = dto.imageURL?.url else { return nil }
            guard urlString.lowercased().hasPrefix("data:"),
                  let commaIndex = urlString.firstIndex(of: ",")
            else { return nil }
            let header = String(urlString[..<commaIndex])
            let body = String(urlString[urlString.index(after: commaIndex)...])
            let mime = header
                .replacingOccurrences(of: "data:", with: "")
                .replacingOccurrences(of: ";base64", with: "")
            guard let data = Data(base64Encoded: body) else { return nil }
            return ImageContent(data: data, mimeType: mime.isEmpty ? nil : mime)
        }
    }
}
