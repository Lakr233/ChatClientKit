//
//  ResponseIntegrationTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/12/06.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteResponsesChatClient OpenRouter Integration")
struct ResponseIntegrationTests {
    @Test(
        "Responses request returns content",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func responsesRequestReturnsContent() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let response = try await client.responses {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("You are a concise assistant."))
                ChatRequest.Message.user(content: .text("What is the capital of France?"))
            }
            ChatRequest.temperature(0.3)
        }

        guard let content = response.textValue else {
            Issue.record("Response contained no message content.")
            return
        }

        #expect(!content.isEmpty, "Expected OpenRouter responses content to be non-empty.")
    }

    @Test(
        "Responses streaming yields chunks",
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func responsesStreamingYieldsChunks() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let stream = try await client.streamingResponses {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("Respond with short poetic lines."))
                ChatRequest.Message.user(content: .text("Compose a haiku about integration tests."))
            }
        }

        var collected = ""
        for try await object in stream {
            if case let .chatCompletionChunk(chunk) = object,
               let delta = chunk.choices.first?.delta.content
            {
                collected += delta
            }
        }

        let normalized = collected.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        #expect(!normalized.isEmpty, "Expected streaming response to include text.")
    }
}
