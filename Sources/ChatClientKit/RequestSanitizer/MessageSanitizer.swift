//
//  MessageSanitizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

public enum DefaultMessageSanitizerConfiguration {
    public nonisolated(unsafe) static var placeholderText = "." // keep this dot
}

enum MessageSanitizer {
    nonisolated(unsafe) static var placeholderText: String {
        get { DefaultMessageSanitizerConfiguration.placeholderText }
        set { DefaultMessageSanitizerConfiguration.placeholderText = newValue }
    }

    static func ensureToolResponses(messages: inout [ChatRequestBody.Message]) {
        let existingToolResponseIDs: Set<String> = Set(
            messages.compactMap { message in
                if case let .tool(_, toolCallID) = message {
                    toolCallID
                } else {
                    nil
                }
            },
        )

        var sanitized: [ChatRequestBody.Message] = []
        sanitized.reserveCapacity(messages.count + 2)
        var insertedPlaceholderIDs: Set<String> = []

        for message in messages {
            sanitized.append(message)

            guard case let .assistant(_, toolCalls, _) = message,
                  let toolCalls,
                  !toolCalls.isEmpty
            else {
                continue
            }

            for toolCall in toolCalls {
                guard !existingToolResponseIDs.contains(toolCall.id) else { continue }
                guard insertedPlaceholderIDs.insert(toolCall.id).inserted else { continue }
                sanitized.append(.tool(content: .text(placeholderText), toolCallID: toolCall.id))
            }
        }

        messages = sanitized
    }

    static func ensureTrailingUserText(messages: inout [ChatRequestBody.Message]) {
        guard !messages.lastIsUserText else { return }
        messages.append(.user(content: .text(placeholderText)))
    }

    static func mergeSystemMessages(_ messages: [ChatRequestBody.Message]) -> [ChatRequestBody.Message] {
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

    static func flattenSystemContent(
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
