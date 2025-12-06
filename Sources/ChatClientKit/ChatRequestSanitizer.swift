//
//  ChatRequestSanitizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

protocol ChatRequestSanitizing: Sendable {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody
}

struct ChatRequestSanitizer: ChatRequestSanitizing {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody {
        let mergedSystemMessages = mergeSystemMessages(body.messages)
        let sanitizedMessages = sanitizeMessages(mergedSystemMessages)
        var sanitizedBody = ChatRequestBody(
            messages: sanitizedMessages,
            maxCompletionTokens: body.maxCompletionTokens,
            stream: body.stream,
            temperature: body.temperature,
            tools: body.tools,
        )
        sanitizedBody.model = body.model
        sanitizedBody.stream = body.stream
        return sanitizedBody
    }

    private func sanitizeMessages(_ messages: [ChatRequestBody.Message]) -> [ChatRequestBody.Message] {
        var sanitized: [ChatRequestBody.Message] = []
        sanitized.reserveCapacity(messages.count + 2)

        for message in messages {
            if case .assistant = message {
                if let last = sanitized.last {
                    if !last.isUser {
                        sanitized.append(.user(content: .text("")))
                    }
                } else {
                    sanitized.append(.user(content: .text("")))
                }
            }
            sanitized.append(message)
        }

        if !sanitized.lastIsUserText {
            sanitized.append(.user(content: .text("")))
            // 我们不极致追求性能，我们追求广泛的兼容性和可用性。
            // 通过保证 user 结尾，大多数厂商会忽略思考内容的特殊格式，从而提升兼容性。
        }

        return sanitized
    }

    private func mergeSystemMessages(_ messages: [ChatRequestBody.Message]) -> [ChatRequestBody.Message] {
        var systemSegments: [String] = []
        var systemName: String?
        var hasSystemMessage = false
        var nonSystemMessages: [ChatRequestBody.Message] = []

        for message in messages {
            switch message {
            case let .system(content, name):
                hasSystemMessage = true
                let segment = flattenSystemContent(content)
                if !segment.isEmpty {
                    systemSegments.append(segment)
                }
                if systemName == nil {
                    systemName = name
                }
            default:
                nonSystemMessages.append(message)
            }
        }

        guard hasSystemMessage else { return messages }

        let combined = systemSegments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        if combined.isEmpty {
            return nonSystemMessages
        }

        let normalizedContent: ChatRequestBody.Message.MessageContent<String, [String]> = .text(combined)

        var merged: [ChatRequestBody.Message] = [
            .system(content: normalizedContent, name: systemName),
        ]
        merged.append(contentsOf: nonSystemMessages)
        return merged
    }

    private func flattenSystemContent(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>,
    ) -> String {
        switch content {
        case let .text(text):
            text
        case let .parts(parts):
            parts.joined(separator: "\n")
        }
    }
}

private extension ChatRequestBody.Message {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    var isUserText: Bool {
        guard case let .user(content, _) = self else { return false }
        if case .text = content { return true }
        return false
    }
}

private extension [ChatRequestBody.Message] {
    var lastIsUserText: Bool {
        guard let last else { return false }
        return last.isUserText
    }
}

struct EmptyChatRequestSanitizer: ChatRequestSanitizing {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody {
        body
    }
}
