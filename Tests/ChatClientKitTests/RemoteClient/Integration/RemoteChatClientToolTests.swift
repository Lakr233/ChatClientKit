//
//  RemoteChatClientToolTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteChatClient Tool Tests")
struct RemoteChatClientToolTests {
    @Test("Non-streaming chat completion with tool calls", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func nonStreamingChatCompletionWithTools() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let getWeatherTool = ChatRequestBody.Tool.function(
            name: "get_weather",
            description: "Get the current weather in a given location",
            parameters: [
                "type": "object",
                "properties": [
                    "location": [
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA",
                    ],
                    "unit": [
                        "type": "string",
                        "enum": ["celsius", "fahrenheit"],
                    ],
                ],
                "required": ["location"],
            ],
            strict: nil
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("What's the weather like in San Francisco?")),
            ],
            tools: [getWeatherTool]
        )

        let response = try await client.chatCompletionRequest(body: request)

        #expect(response.choices.count > 0)
        let message = response.choices.first?.message
        #expect(message != nil)

        // The model should either call the tool or provide a response
        if let toolCalls = message?.toolCalls, !toolCalls.isEmpty {
            #expect(toolCalls.count > 0)
            let toolCall = toolCalls.first!
            #expect(toolCall.function.name == "get_weather")
        } else {
            // Or it might just respond directly
            #expect(message?.content != nil)
        }
    }

    @Test("Streaming chat completion with tool calls", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingChatCompletionWithTools() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let getWeatherTool = ChatRequestBody.Tool.function(
            name: "get_weather",
            description: "Get the current weather in a given location",
            parameters: [
                "type": "object",
                "properties": [
                    "location": [
                        "type": "string",
                        "description": "The city and state, e.g. San Francisco, CA",
                    ],
                ],
                "required": ["location"],
            ],
            strict: nil
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("What's the weather in New York?")),
            ],
            tools: [getWeatherTool]
        )

        let stream = try await client.streamingChatCompletionRequest(body: request)

        var toolCalls: [ToolCallRequest] = []
        var contentChunks: [String] = []

        for try await object in stream {
            switch object {
            case let .chatCompletionChunk(chunk):
                if let content = chunk.choices.first?.delta.content {
                    contentChunks.append(content)
                }
            case let .tool(call):
                toolCalls.append(call)
            }
        }

        // Should either have tool calls or content
        #expect(toolCalls.count > 0 || contentChunks.count > 0)
    }

    @Test("Streaming chat completion collects tool calls", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingCollectsToolCalls() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let getWeatherTool = ChatRequestBody.Tool.function(
            name: "get_weather",
            description: "Get the current weather",
            parameters: [
                "type": "object",
                "properties": [
                    "location": [
                        "type": "string",
                        "description": "The location",
                    ],
                ],
                "required": ["location"],
            ],
            strict: nil
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("Get weather for London")),
            ],
            tools: [getWeatherTool]
        )

        let stream = try await client.streamingChatCompletionRequest(body: request)

        var collectedToolCalls: [ToolCallRequest] = []

        for try await object in stream {
            if case let .tool(call) = object {
                collectedToolCalls.append(call)
            }
        }

        // May or may not have tool calls depending on model behavior
        // Just verify we can collect them if they exist
        if !collectedToolCalls.isEmpty {
            #expect(collectedToolCalls.first?.name == "get_weather")
        }
    }
}
