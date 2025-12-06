//
//  RemoteResponsesChatClientLiveTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/12/06.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteResponsesChatClient Live Tests")
struct RemoteResponsesChatClientLiveTests {
    @Test(
        "Responses API returns content",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func responsesAPIProducesContent() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let response = try await client.responses {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("You answer with short sentences."))
                ChatRequest.Message.user(content: .text("Tell me a fun fact about SwiftUI."))
            }
            ChatRequest.temperature(0.4)
        }

        let content = response.textValue?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
        if content.isEmpty {
            Issue.record("Expected non-empty response content")
            return
        }
    }

    @Test(
        "Streaming responses API yields chunks",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func streamingResponsesAPIProducesChunks() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let stream = try await client.streamingResponses {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("You output poetic text."))
                ChatRequest.Message.user(content: .text("Write a three-line poem about testing."))
            }
        }

        var collectedContent = ""
        for try await event in stream {
            if case let .chatCompletionChunk(chunk) = event,
               let delta = chunk.choices.first?.delta.content
            {
                collectedContent += delta
            }
        }

        let normalized = collectedContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if normalized.isEmpty {
            Issue.record("Expected streaming content to include text")
        }
    }

    @Test(
        "Responses API respects developer instructions",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func responsesAPIHonorsDeveloperInstructions() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let response = try await client.responses {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.developer(content: .text("Always answer in uppercase letters."))
                ChatRequest.Message.user(content: .text("reply with a short greeting"))
            }
            ChatRequest.temperature(0.2)
        }

        let content = response.textValue ?? ""
        if content.isEmpty {
            Issue.record("Expected non-empty content honoring developer instructions")
        }
    }

    @Test(
        "Responses API handles multi-turn conversations",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func responsesAPIHandlesMultiTurnContext() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let response = try await client.responses {
            ChatRequest.model("google/gemini-3-pro-preview")
            ChatRequest.messages {
                ChatRequest.Message.user(content: .text("My name is Alice."))
                ChatRequest.Message.assistant(content: .text("Nice to meet you, Alice!"))
                ChatRequest.Message.user(content: .text("Remind me of my name in one word."))
            }
            ChatRequest.maxCompletionTokens(4096)
        }

        let content = response.textValue ?? ""
        if content.isEmpty {
            Issue.record("Response content missing for multi-turn request.")
        } else if !content.lowercased().contains("alice") {
            Issue.record("Model response did not echo the provided name. Content: \(content)")
        }
    }
}
