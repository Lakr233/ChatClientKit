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

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        #expect(content.isEmpty == false)
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

        let stream = try await client.streamingChat(body: request)

        var fullContent = ""
        for try await chunk in stream {
            if let content = chunk.textValue {
                fullContent += content
            }
        }

        #expect(fullContent.isEmpty == false)
    }

    @Test("Image generation returns image payload", .enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func imageGenerationProducesImage() async throws {
        let client = TestHelpers.makeOpenRouterImageClient()

        let request = ChatRequestBody(
            messages: [
                .system(content: .text("You are a professional icon designer. You must generate an image each time.")),
                .user(content: .text("Generate a black-and-white line-art cat icon. Keep it simple with clear outlines.")),
            ],
            maxCompletionTokens: nil,
            stream: false,
            temperature: 0.4,
        )

        let response: ChatResponse = try await client.chat(body: request)
        let imageData = response.images.first?.data

        #expect(imageData != nil, "Expected image payload from google/gemini-2.5-flash-image")
        if imageData == nil {
            logger.error("imageGenerationProducesImage: missing image payload, model: \(client.model), baseURL: \(client.baseURL ?? "nil")")
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

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
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

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
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

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
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

        let stream = try await client.streamingChat(body: request)

        var fullContent = ""
        for try await chunk in stream {
            if let content = chunk.textValue {
                fullContent += content
            }
        }

        #expect(fullContent.isEmpty == false)
    }
}
