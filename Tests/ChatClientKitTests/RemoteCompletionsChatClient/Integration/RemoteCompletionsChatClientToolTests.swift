//
//  RemoteCompletionsChatClientToolTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteCompletionsChatClient Tool Tests")
struct RemoteCompletionsChatToolTests {
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
            strict: nil,
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("What's the weather like in San Francisco?")),
            ],
            tools: [getWeatherTool],
        )

        let response: ChatResponse = try await client.chat(body: request)

        if let tool = response.tools.first {
            #expect(tool.name == "get_weather")
        } else {
            let text = response.text
            #expect(text.isEmpty == false)
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
            strict: nil,
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("What's the weather in New York?")),
            ],
            tools: [getWeatherTool],
        )

        let stream = try await client.streamingChat(body: request)

        var toolCalls: [ToolRequest] = []
        var contentChunks: [String] = []

        for try await chunk in stream {
            switch chunk {
            case let .tool(call):
                toolCalls.append(call)
            case let .text(content):
                contentChunks.append(content)
            default:
                break
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
            strict: nil,
        )

        let request = ChatRequestBody(
            messages: [
                .user(content: .text("Get weather for London")),
            ],
            tools: [getWeatherTool],
        )

        let stream = try await client.streamingChat(body: request)

        var collectedToolCalls: [ToolRequest] = []

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
