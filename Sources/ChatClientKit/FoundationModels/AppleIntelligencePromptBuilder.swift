import Foundation

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
            .joined(separator: "\n")
    }

    static func makePrompt(from messages: [ChatRequestBody.Message]) -> String {
        var latestUserIndex: Int?
        var latestUserLine: String?

        for (index, message) in messages.enumerated().reversed() {
            guard case let .user(content, name) = message else { continue }
            let text = extractTextFromUser(content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            latestUserIndex = index
            latestUserLine = makeRoleLine(role: "User", name: name, text: text)
            break
        }

        var contextLines: [String] = []
        for (index, message) in messages.enumerated() {
            if index == latestUserIndex { continue }
            switch message {
            case .system, .developer:
                continue
            case let .user(content, name):
                let text = extractTextFromUser(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    contextLines.append(makeRoleLine(role: "User", name: name, text: text))
                }
            case let .assistant(content, name, _, _):
                guard let assistantText = extractTextFromAssistant(content)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !assistantText.isEmpty
                else { continue }
                contextLines.append(makeRoleLine(role: "Assistant", name: name, text: assistantText))
            case let .tool(content, toolCallID):
                let text = extractPlainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    contextLines.append("Tool(\(toolCallID)): \(text)")
                }
            }
        }

        let context = contextLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if let latestUserLine, !latestUserLine.isEmpty {
            var sections: [String] = []
            if !context.isEmpty {
                sections.append("Conversation so far:\n\(context)")
            }
            sections.append(latestUserLine)
            return sections.joined(separator: "\n\n")
        }

        if context.isEmpty {
            return "Continue the conversation helpfully."
        }

        return context
    }
}

private func extractPlainText(
    _ content: ChatRequestBody.Message.MessageContent<String, [String]>
) -> String {
    switch content {
    case let .text(text):
        text
    case let .parts(parts):
        parts.joined(separator: " ")
    }
}

private func extractTextFromUser(
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

private func extractTextFromAssistant(
    _ content: ChatRequestBody.Message.MessageContent<String, [String]>?
) -> String? {
    guard let content else { return nil }
    let text = extractPlainText(content).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

private func makeRoleLine(role: String, name: String?, text: String) -> String {
    if let name, !name.isEmpty {
        return "\(role) (\(name)): \(text)"
    }
    return "\(role): \(text)"
}
