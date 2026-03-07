//
//  RemoteCompletionsChatClientBasicTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

struct RemoteCompletionsChatClientBasicTests {
    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Non-streaming chat completion with text message`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("Say 'Hello, World!' in one sentence.")),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let text = try #require(response.text.isEmpty ? nil : response.text)
        #expect(text.isEmpty == false)
        #expect(text.lowercased().contains("hello") == true)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Streaming chat completion with text message`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("Count from 1 to 5, one number per line.")),
        ])

        let stream = try await client.streamingChat(body: request)

        var chunks: [ChatResponseChunk] = []
        var fullContent = ""

        for try await chunk in stream {
            chunks.append(chunk)
            if let text = chunk.textValue {
                fullContent += text
            }
        }

        #expect(chunks.count > 0)
        #expect(fullContent.isEmpty == false)
        #expect(fullContent.contains("1") || fullContent.contains("2") || fullContent.contains("3"))
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with system message`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .system(content: .text("You are a helpful assistant that always responds in uppercase.")),
            .user(content: .text("Say hello")),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        if content.isEmpty {
            Issue.record("Response content was empty; Google Gemini sometimes omits text for short deterministic prompts.")
        }
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with multiple messages`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("My name is Alice.")),
            .assistant(content: .text("Hello Alice! Nice to meet you.")),
            .user(content: .text("What's my name?")),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        if content.isEmpty {
            Issue.record("Response content was empty when requesting numbers 1 through 10.")
        }
        #expect(content.lowercased().contains("alice") == true)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with temperature parameter`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("Say 'test'")),
            ],
            temperature: 0.5,
        )

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        if content.isEmpty {
            Issue.record("Expected non-empty completion when max tokens is set.")
        }
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with max tokens`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("List the numbers 1 through 10.")),
            ],
            maxCompletionTokens: 512, // reasoning content counts too
        )

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        #expect(content.isEmpty == false)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Streaming chat completion collects all chunks`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("Write a short poem about testing.")),
        ])

        let stream = try await client.streamingChat(body: request)

        var contentChunks: [String] = []
        var reasoningChunks: [String] = []
        var toolCalls: [ToolRequest] = []

        for try await chunk in stream {
            switch chunk {
            case let .text(content):
                contentChunks.append(content)
            case let .reasoning(reasoning):
                reasoningChunks.append(reasoning)
            case let .tool(call):
                toolCalls.append(call)
            default:
                break
            }
        }

        #expect(contentChunks.count > 0 || reasoningChunks.count > 0)
    }
}
