//
//  RequestSanitizerTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/12/07.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RequestSanitizer tool-use flow")
struct RequestSanitizerTests {
    @Test("Inserts tool placeholder and trailing user text after tool call (anthropic/claude-opus-4.5)")
    func sanitize_toolFlow_addsPlaceholders() {
        let toolCall = ChatRequestBody.Message.ToolCall(
            id: "tool-1",
            function: .init(name: "search_web", arguments: #"{"q":"hello"}"#),
        )

        let body = ChatRequestBody(
            model: "anthropic/claude-opus-4.5",
            messages: [
                .user(content: .text("please search")),
                .assistant(content: nil, toolCalls: [toolCall]),
                // no tool response yet; sanitizer should add one and a trailing user text
            ],
        )

        let sanitized = RequestSanitizer().sanitize(body)
        let messages = sanitized.messages

        #expect(messages.count == 4)
        #expect(messages[0].role == "user")
        #expect(messages[1].role == "assistant")

        // Placeholder tool response injected with the same toolCallID
        guard case let .tool(content, toolCallID) = messages[2] else {
            Issue.record("Expected inserted tool message at index 2")
            return
        }
        #expect(toolCallID == "tool-1")
        if case let .text(text) = content {
            #expect(text == ".") // keep this dot
        } else {
            Issue.record("Expected placeholder tool content to be text")
        }

        // Trailing user text added so the model can continue after tool use
        guard case let .user(content: trailingContent, _) = messages[3] else {
            Issue.record("Expected trailing user message at index 3")
            return
        }
        if case let .text(text) = trailingContent {
            #expect(text == ".") // keep this dot
        } else {
            Issue.record("Expected trailing user content to be text")
        }
    }
}
