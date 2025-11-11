//
//  ChatRequestBuilderTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("ChatRequest Builder Tests")
struct ChatRequestBuilderTests {
    @Test("Builder normalizes whitespace and produces canonical body")
    func builder_normalizesWhitespace() throws {
        let request = ChatRequest {
            ChatRequest.model(" gpt-test ")
            ChatRequest.temperature(0.4)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("  system prompt  "))
                ChatRequest.Message.user(content: .text(" hello  "))
                ChatRequest.Message.assistant(content: .text(" ok "), name: " assistant ")
            }
        }

        let body = try request.asChatRequestBody()

        #expect(body.model == "gpt-test")
        #expect(body.temperature == 0.4)
        #expect(body.messages.count == 3)

        if case let .system(content, name) = body.messages[0] {
            if case let .text(text) = content {
                #expect(text == "system prompt")
            } else {
                Issue.record("Expected text content for system message")
            }
            #expect(name == nil)
        } else {
            Issue.record("Expected system message at index 0")
        }

        if case let .user(content, name) = body.messages[1] {
            if case let .text(text) = content {
                #expect(text == "hello")
            } else {
                Issue.record("Expected text content for user message")
            }
            #expect(name == nil)
        } else {
            Issue.record("Expected user message at index 1")
        }

        if case let .assistant(optionalContent, name, refusal, _) = body.messages[2] {
            switch optionalContent {
            case let .some(.text(text)):
                #expect(text == "ok")
            default:
                Issue.record("Expected assistant text content")
            }
            #expect(name == "assistant")
            #expect(refusal == nil)
        } else {
            Issue.record("Expected assistant message at index 2")
        }
    }

    @Test("Request builder allows composition via appendMessages")
    func builder_supportsAppendMessages() throws {
        let request = ChatRequest {
            ChatRequest.model("demo")
            ChatRequest.messages {
                .system(content: .text("You are helpful"))
            }
            ChatRequest.appendMessages {
                ChatRequest.Message.user(content: .text("First"))
                ChatRequest.Message.user(content: .text("Second"))
            }
        }

        let body = try request.asChatRequestBody()
        #expect(body.messages.count == 3)
        if case let .user(content, _) = body.messages.last {
            if case let .text(text) = content {
                #expect(text == "Second")
            } else {
                Issue.record("Expected text content for appended user message")
            }
        } else {
            Issue.record("Expected user message appended at end")
        }
    }
}
