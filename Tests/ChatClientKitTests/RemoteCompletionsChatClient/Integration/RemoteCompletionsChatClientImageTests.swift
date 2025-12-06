//
//  RemoteCompletionsChatClientImageTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

@Suite("RemoteCompletionsChatClient Image Tests")
struct RemoteCompletionsChatClientImageTests {
    @Test("Non-streaming chat completion with image input", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func nonStreamingChatCompletionWithImage() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("What color is this image?"),
                .imageURL(imageURL),
            ])),
        ])

        let response = try await client.chatCompletionRequest(body: request)

        let content = response.textValue ?? ""
        #expect(content.isEmpty == false)
        // The image is red, so the response should mention red
        #expect(content.lowercased().contains("red") == true)
    }

    @Test("Streaming chat completion with image input", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingChatCompletionWithImage() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("Describe this image in one sentence."),
                .imageURL(imageURL),
            ])),
        ])

        let stream = try await client.streamingChatCompletionRequest(body: request)

        var fullContent = ""
        for try await chunk in stream {
            if case let .chatCompletionChunk(completionChunk) = chunk {
                if let content = completionChunk.choices.first?.delta.content {
                    fullContent += content
                }
            }
        }

        #expect(fullContent.isEmpty == false)
    }

    @Test("Image generation returns image payload", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func imageGenerationProducesImage() async throws {
        let client = TestHelpers.makeOpenRouterImageClient()

        let request = ChatRequestBody(
            messages: [.user(content: .text("Create a simple black and white line-art cat icon."))],
            maxCompletionTokens: nil,
            stream: false,
            temperature: 0.4,
        )

        let response = try await client.chatCompletionRequest(body: request)
        let imageData = response.imageData

        if imageData == nil {
            Issue.record("Expected image payload in response.")
        }
    }

    @Test("Chat completion with image and text", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithImageAndText() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("What is the primary color in this image? Answer in one word."),
                .imageURL(imageURL),
            ])),
        ])

        let response = try await client.chatCompletionRequest(body: request)

        let content = response.textValue ?? ""
        #expect(content.isEmpty == false)
    }

    @Test("Chat completion with multiple images", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithMultipleImages() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL1 = TestHelpers.createTestImageDataURL(width: 100, height: 100)
        let imageURL2 = TestHelpers.createTestImageDataURL(width: 200, height: 200)

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("How many images did I send?"),
                .imageURL(imageURL1),
                .imageURL(imageURL2),
            ])),
        ])

        let response = try await client.chatCompletionRequest(body: request)

        let content = response.textValue ?? ""
        #expect(content.isEmpty == false)
    }

    @Test("Chat completion with image detail parameter", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func chatCompletionWithImageDetail() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("Describe this image."),
                .imageURL(imageURL, detail: .high),
            ])),
        ])

        let response = try await client.chatCompletionRequest(body: request)

        let content = response.textValue ?? ""
        #expect(content.isEmpty == false)
    }

    @Test("Streaming chat completion with image in conversation", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func streamingChatCompletionWithImageInConversation() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("What color is this?"),
                .imageURL(imageURL),
            ])),
            .assistant(content: .text("The image is red.")),
            .user(content: .text("What about the shape?")),
        ])

        let stream = try await client.streamingChatCompletionRequest(body: request)

        var fullContent = ""
        for try await chunk in stream {
            if case let .chatCompletionChunk(completionChunk) = chunk {
                if let content = completionChunk.choices.first?.delta.content {
                    fullContent += content
                }
            }
        }

        #expect(fullContent.isEmpty == false)
    }
}
