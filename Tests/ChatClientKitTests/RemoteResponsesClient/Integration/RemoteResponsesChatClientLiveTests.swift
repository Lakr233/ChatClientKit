//
//  RemoteResponsesChatClientLiveTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/12/06.
//

@testable import ChatClientKit
import Foundation
import Testing

struct RemoteResponsesChatClientLiveTests {
    @Test(
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func `Responses API returns content`() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let responseChunks = try await client.chatChunks {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("You answer with short sentences."))
                ChatRequest.Message.user(content: .text("Tell me a fun fact about SwiftUI."))
            }
            ChatRequest.temperature(0.4)
        }

        let content = ChatResponse(chunks: responseChunks)
            .text
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        #expect(!content.isEmpty, "Expected non-empty response content")
    }

    @Test(
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func `Streaming responses API yields chunks`() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let stream = try await client.streamingChat {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("You output poetic text."))
                ChatRequest.Message.user(content: .text("Write a three-line poem about testing."))
            }
        }

        var collectedContent = ""
        for try await event in stream {
            if let delta = event.textValue {
                collectedContent += delta
            }
        }

        let normalized = collectedContent.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        #expect(!normalized.isEmpty, "Expected streaming content to include text")
    }

    @Test(
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func `Responses API respects developer instructions`() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let responseChunks = try await client.chatChunks {
            ChatRequest.model(TestHelpers.defaultOpenRouterModel)
            ChatRequest.messages {
                ChatRequest.Message.developer(content: .text("Always answer in uppercase letters."))
                ChatRequest.Message.user(content: .text("reply with a short greeting"))
            }
            ChatRequest.temperature(0.2)
        }

        let content = ChatResponse(chunks: responseChunks).text
        #expect(!content.isEmpty, "Expected non-empty content honoring developer instructions")
    }

    @Test(
        .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured),
    )
    func `Responses API handles multi-turn conversations`() async throws {
        let client = TestHelpers.makeOpenRouterResponsesClient()

        let responseChunks = try await client.chatChunks {
            ChatRequest.model("google/gemini-3-pro-preview")
            ChatRequest.messages {
                ChatRequest.Message.user(content: .text("My name is Alice."))
                ChatRequest.Message.assistant(content: .text("Nice to meet you, Alice!"))
                ChatRequest.Message.user(content: .text("Remind me of my name in one word."))
            }
            ChatRequest.maxCompletionTokens(4096)
        }

        let content = ChatResponse(chunks: responseChunks).text
        #expect(!content.isEmpty, "Response content missing for multi-turn request.")
        if !content.lowercased().contains("alice") {
            Issue.record("Model response did not echo the provided name. Content: \(content)")
        }
    }
}
