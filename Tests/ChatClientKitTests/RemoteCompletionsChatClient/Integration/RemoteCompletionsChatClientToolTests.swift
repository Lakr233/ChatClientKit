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

    @Test(
        "Tool call roundtrip preserves reasoning_details",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured)
    )
    func toolCallRoundtripPreservesReasoningDetails() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let getWeatherTool = ChatRequestBody.Tool.function(
            name: "get_weather",
            description: "Fetch the current weather for a given location.",
            parameters: [
                "type": "object",
                "properties": [
                    "city": ["type": "string"],
                ],
                "required": ["city"],
            ],
            strict: nil
        )

        var messagesBuffer: [ChatRequestBody.Message] = [
            .system(content: .text("Use the provided tool to answer. Do not answer directly.")),
            .user(content: .text("Call get_weather for Paris and then answer with the result.")),
        ]

        // First turn: force the model to call the tool.
        let firstRequest = ChatRequestBody(
            messages: messagesBuffer,
            tools: [getWeatherTool]
        )

        let firstResponse = try await client.chatCompletionRequest(body: firstRequest)
        let assistant = try #require(firstResponse.choices.first?.message)
        let toolCall = try #require(assistant.toolCalls?.first)
        let reasoningDetails = try #require(assistant.reasoningDetails)
        #expect(!reasoningDetails.isEmpty)

        // Second turn: pass tool result back, preserving reasoning_details.
        let toolResultJSON = #"{"temperature":22,"unit":"celsius"}"#

        messagesBuffer.append(contentsOf: [
            .assistant(
                content: assistant.content.map(ChatRequestBody.Message.MessageContent.text),
                toolCalls: assistant.toolCalls?.compactMap { input in
                    .init(id: input.id, function: .init(name: input.function.name, arguments: input.function.argumentsRaw))
                },
                reasoning: assistant.reasoning ?? assistant.reasoningContent,
                reasoningDetails: reasoningDetails
            ),
            .tool(content: .text(toolResultJSON), toolCallID: toolCall.id),
        ])
        let followUp = ChatRequestBody(
            messages: messagesBuffer,
            tools: [getWeatherTool]
        )

        // Validate request body keeps reasoning_details before sending.
        let encoded = try JSONEncoder().encode(followUp.mergingAdjacentAssistantMessages())
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let messages = try #require(bodyJSON["messages"] as? [[String: Any]])
        let assistantPayload = try #require(messages[2]["reasoning_details"] as? [[String: Any]])
        #expect(assistantPayload.isEmpty == false)

        // Perform follow-up request to ensure payload is accepted.
        let secondResponse = try await client.chatCompletionRequest(body: followUp)
        #expect(secondResponse.choices.first?.message.content?.isEmpty == false)
    }
}
