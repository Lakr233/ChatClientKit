//
//  RemoteCompletionsChatClientBasicTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteCompletionsChatClient Basic Tests")
struct RemoteCompletionsChatClientBasicTests {
    @Test("Non-streaming chat completion with text message", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func nonStreamingChatCompletion() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("Say 'Hello, World!' in one sentence.")),
        ])

        let response = try await client.chat(body: request)

        let text = try #require(response.textValue)
        #expect(text.isEmpty == false)
        #expect(text.lowercased().contains("hello") == true)
    }

    @Test("Streaming chat completion with text message", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingChatCompletion() async throws {
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

    @Test("Chat completion with system message", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithSystemMessage() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .system(content: .text("You are a helpful assistant that always responds in uppercase.")),
            .user(content: .text("Say hello")),
        ])

        let response = try await client.chat(body: request)

        let content = response.textValue ?? ""
        if content.isEmpty {
            Issue.record("Response content was empty; Google Gemini sometimes omits text for short deterministic prompts.")
        }
    }

    @Test("Chat completion with multiple messages", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithMultipleMessages() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("My name is Alice.")),
            .assistant(content: .text("Hello Alice! Nice to meet you.")),
            .user(content: .text("What's my name?")),
        ])

        let response = try await client.chat(body: request)

        let content = response.textValue ?? ""
        if content.isEmpty {
            Issue.record("Response content was empty when requesting numbers 1 through 10.")
        }
        #expect(content.lowercased().contains("alice") == true)
    }

    @Test("Chat completion with temperature parameter", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithTemperature() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("Say 'test'")),
            ],
            temperature: 0.5,
        )

        let response = try await client.chat(body: request)

        let content = response.textValue ?? ""
        if content.isEmpty {
            Issue.record("Expected non-empty completion when max tokens is set.")
        }
    }

    @Test("Chat completion with max tokens", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithMaxTokens() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("List the numbers 1 through 10.")),
            ],
            maxCompletionTokens: 512, // reasoning content counts too
        )

        let response = try await client.chat(body: request)

        let content = response.textValue ?? ""
        #expect(content.isEmpty == false)
    }

    @Test("Streaming chat completion collects all chunks", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingCollectsAllChunks() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let request = ChatRequestBody(messages: [
            .user(content: .text("Write a short poem about testing.")),
        ])

        let stream = try await client.streamingChat(body: request)

        var contentChunks: [String] = []
        var reasoningChunks: [String] = []
        var toolCalls: [ToolRequest] = []

        for try await object in stream {
            switch object {
            case let .chatCompletionChunk(chunk):
                if let delta = chunk.choices.first?.delta {
                    if let content = delta.content {
                        contentChunks.append(content)
                    }
                    if let reasoning = delta.reasoningContent {
                        reasoningChunks.append(reasoning)
                    }
                }
            case let .tool(call):
                toolCalls.append(call)
            }
        }

        #expect(contentChunks.count > 0 || reasoningChunks.count > 0)
    }
}
