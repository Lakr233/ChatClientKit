//
//  RemoteResponsesChatResponseDecoder.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation

struct RemoteResponsesChatResponseDecoder {
    private let decoder: JSONDecoding

    init(decoder: JSONDecoding = JSONDecoderWrapper()) {
        self.decoder = decoder
    }

    func decodeResponse(from data: Data) throws -> ChatResponseBody {
        let response = try decoder.decode(ResponsesAPIResponse.self, from: data)
        return response.asChatResponseBody()
    }
}

struct ResponsesAPIResponse: Decodable {
    let id: String?
    let createdAt: Double?
    let model: String?
    let output: [ResponsesOutputItem]?
    let status: String?
    let error: ResponsesErrorPayload?

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt = "created_at"
        case model
        case output
        case status
        case error
    }

    func asChatResponseBody() -> ChatResponseBody {
        let outputItems = output ?? []
        var choices: [ChatChoice] = []
        var pendingToolCalls: [ToolCall] = []

        for item in outputItems {
            if let toolCall = item.asToolCall() {
                if let lastIndex = choices.indices.last {
                    choices[lastIndex] = choices[lastIndex].appending(toolCalls: [toolCall])
                } else {
                    pendingToolCalls.append(toolCall)
                }
                continue
            }

            guard var choice = item.asChoice(toolCalls: []) else { continue }

            if !pendingToolCalls.isEmpty {
                choice = choice.appending(toolCalls: pendingToolCalls)
                pendingToolCalls.removeAll()
            }

            choices.append(choice)
        }

        if !pendingToolCalls.isEmpty {
            let message = ChoiceMessage(content: nil, role: "assistant", toolCalls: pendingToolCalls)
            choices.append(ChatChoice(finishReason: "tool_calls", message: message))
        }

        if status?.lowercased() == "incomplete", let lastIndex = choices.indices.last {
            var lastChoice = choices[lastIndex]
            if lastChoice.finishReason == "stop" || lastChoice.finishReason == nil {
                lastChoice.finishReason = "length"
                choices[lastIndex] = lastChoice
            }
        }

        let createdValue = Int(createdAt ?? Date().timeIntervalSince1970)
        let modelName = model ?? ""

        return ChatResponseBody(choices: choices, created: createdValue, model: modelName)
    }
}

struct ResponsesOutputItem: Decodable {
    let id: String?
    let type: String?
    let role: String?
    let content: [ResponsesContentPart]?
    let name: String?
    let callId: String?
    let arguments: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case content
        case name
        case callId = "call_id"
        case arguments
    }

    func asToolCall() -> ToolCall? {
        guard type == "function_call" else { return nil }
        let identifier = callId ?? id ?? UUID().uuidString
        let functionName = name ?? ""
        return ToolCall(id: identifier, type: "function", function: Function(name: functionName, argumentsJSON: arguments))
    }

    func asChoice(toolCalls: [ToolCall]) -> ChatChoice? {
        guard type == "message" else { return nil }
        let textSegments = content?.compactMap(\.resolvedContent) ?? []
        let reasoningSegments = content?.compactMap(\.reasoningContent) ?? []
        let hasRefusal = content?.contains(where: \.isRefusal) ?? false
        let hasToolCalls = !toolCalls.isEmpty

        let message = ChoiceMessage(
            content: textSegments.isEmpty ? nil : textSegments.joined(),
            reasoning: nil,
            reasoningContent: reasoningSegments.isEmpty ? nil : reasoningSegments.joined(separator: "\n"),
            role: role ?? "assistant",
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
        )
        let finishReason: String? = if hasRefusal {
            "refusal"
        } else if hasToolCalls {
            "tool_calls"
        } else {
            "stop"
        }
        return ChatChoice(finishReason: finishReason, message: message)
    }
}

struct ResponsesContentPart: Decodable {
    let type: String
    let text: String?
}

extension ResponsesContentPart {
    var resolvedContent: String? {
        switch type {
        case "output_text", "input_text":
            text
        case let value where value.contains("refusal"):
            text ?? "[REFUSAL]"
        case let value where value.contains("audio"):
            // Placeholder for unsupported audio output in chat abstraction.
            text ?? "[AUDIO]"
        case let value where value.contains("image"):
            // Placeholder for unsupported image output in chat abstraction.
            text ?? "[IMAGE]"
        case let value where value.contains("file"):
            // Placeholder for unsupported file output in chat abstraction.
            text ?? "[FILE]"
        default:
            nil
        }
    }

    var reasoningContent: String? {
        if type.contains("reasoning"), let text {
            return text
        }
        return nil
    }

    var isRefusal: Bool {
        type.contains("refusal")
    }

    var outputTextContent: String? {
        switch type {
        case "output_text", "input_text":
            text
        default:
            nil
        }
    }

    var reasoningTextContent: String? {
        type.contains("reasoning") ? text : nil
    }

    var refusalContent: String? {
        type.contains("refusal") ? (text ?? "[REFUSAL]") : nil
    }
}

struct ResponsesErrorPayload: Decodable {
    let code: String?
    let message: String?
    let param: String?
}

private extension ChatChoice {
    func appending(toolCalls newCalls: [ToolCall]) -> ChatChoice {
        guard !newCalls.isEmpty else { return self }
        var mergedToolCalls = message.toolCalls ?? []
        mergedToolCalls.append(contentsOf: newCalls)
        let finish: String = finishReason == "refusal" ? "refusal" : "tool_calls"
        let updatedMessage = ChoiceMessage(
            content: message.content,
            reasoning: message.reasoning,
            reasoningContent: message.reasoningContent,
            role: message.role,
            toolCalls: mergedToolCalls,
        )
        return ChatChoice(finishReason: finish, message: updatedMessage)
    }
}
