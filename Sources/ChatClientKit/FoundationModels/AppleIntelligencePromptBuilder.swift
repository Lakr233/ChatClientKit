import Foundation
import FoundationModels

enum AppleIntelligencePromptBuilder {
    static func makeInstructions(
        persona: String,
        messages: [ChatRequestBody.Message],
        additionalDirectives: [String]
    ) -> String {
        var blocks: [String] = [persona]

        let supplemental = messages.compactMap { message -> String? in
            switch message {
            case let .system(content, _):
                extractPlainText(content)
            case let .developer(content, _):
                extractPlainText(content)
            default:
                nil
            }
        }

        blocks.append(contentsOf: supplemental)
        blocks.append(contentsOf: additionalDirectives)

        return blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static let continuationPrompt = "Continue the conversation helpfully."

    /// The text passed to the session as this round's prompt: the latest user
    /// message, verbatim. A role label would make it read as a line of a log,
    /// which the on-device model then narrates instead of answering.
    static func makePrompt(from messages: [ChatRequestBody.Message]) -> String {
        guard let index = latestUserIndex(in: messages) else { return continuationPrompt }
        guard case let .user(content, _) = messages[index] else { return continuationPrompt }
        return extractTextFromUser(content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Everything the model sees before the prompt, in source order: earlier
    /// turns and this turn's tool calls and outputs. System and developer
    /// messages go to the instructions instead.
    static func makeHistory(from messages: [ChatRequestBody.Message]) -> [HistoryEntry] {
        let latestUserIndex = latestUserIndex(in: messages)
        var toolNames: [String: String] = [:]
        var entries: [HistoryEntry] = []

        for (index, message) in messages.enumerated() {
            if index == latestUserIndex { continue }
            switch message {
            case .system, .developer:
                continue
            case let .user(content, _):
                let text = extractTextFromUser(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    entries.append(.prompt(text))
                }
            case let .assistant(content, toolCalls, _):
                if let text = extractTextFromAssistant(content) {
                    entries.append(.response(text))
                }
                let calls = (toolCalls ?? []).map { toolCall in
                    toolNames[toolCall.id] = toolCall.function.name
                    return HistoryEntry.ToolCall(
                        id: toolCall.id,
                        name: toolCall.function.name,
                        arguments: toolCall.function.arguments ?? "{}"
                    )
                }
                if !calls.isEmpty {
                    entries.append(.toolCalls(calls))
                }
            case let .tool(content, toolCallID):
                let text = extractPlainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    entries.append(.toolOutput(
                        id: toolCallID,
                        toolName: toolNames[toolCallID] ?? "tool",
                        text: text
                    ))
                }
            }
        }

        return entries
    }

    private static func latestUserIndex(in messages: [ChatRequestBody.Message]) -> Int? {
        messages.indices.last { index in
            guard case let .user(content, _) = messages[index] else { return false }
            return !extractTextFromUser(content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }
}

extension AppleIntelligencePromptBuilder {
    enum HistoryEntry: Equatable {
        struct ToolCall: Equatable {
            let id: String
            let name: String
            let arguments: String
        }

        case prompt(String)
        case response(String)
        case toolCalls([ToolCall])
        case toolOutput(id: String, toolName: String, text: String)
    }
}

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
extension AppleIntelligencePromptBuilder {
    /// A native transcript carrying the instructions and the history, so prior
    /// turns reach the model as real prompt, response and tool entries rather
    /// than as text inside the prompt.
    static func makeTranscript(
        instructions: String,
        tools: [any Tool],
        history: [HistoryEntry]
    ) -> Transcript {
        var entries: [Transcript.Entry] = [
            .instructions(Transcript.Instructions(
                segments: segments(instructions),
                toolDefinitions: tools.map { Transcript.ToolDefinition(tool: $0) }
            )),
        ]

        for entry in history {
            switch entry {
            case let .prompt(text):
                entries.append(.prompt(Transcript.Prompt(segments: segments(text))))
            case let .response(text):
                entries.append(.response(Transcript.Response(assetIDs: [], segments: segments(text))))
            case let .toolCalls(calls):
                entries.append(.toolCalls(Transcript.ToolCalls(calls.map { call in
                    Transcript.ToolCall(
                        id: call.id,
                        toolName: call.name,
                        arguments: (try? GeneratedContent(json: call.arguments))
                            ?? GeneratedContent(call.arguments)
                    )
                })))
            case let .toolOutput(id, toolName, text):
                entries.append(.toolOutput(Transcript.ToolOutput(
                    id: id,
                    toolName: toolName,
                    segments: segments(text)
                )))
            }
        }

        return Transcript(entries: entries)
    }

    private static func segments(_ text: String) -> [Transcript.Segment] {
        text.isEmpty ? [] : [.text(Transcript.TextSegment(content: text))]
    }
}

func extractPlainText(
    _ content: ChatRequestBody.Message.MessageContent<String, [String]>
) -> String {
    switch content {
    case let .text(text):
        text
    case let .parts(parts):
        parts.joined(separator: " ")
    }
}

func extractTextFromUser(
    _ content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>
) -> String {
    switch content {
    case let .text(text):
        text
    case let .parts(parts):
        parts.compactMap { part in
            if case let .text(text) = part { text } else { nil }
        }.joined(separator: " ")
    }
}

func extractTextFromAssistant(
    _ content: ChatRequestBody.Message.MessageContent<String, [String]>?
) -> String? {
    guard let content else { return nil }
    let text = extractPlainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
