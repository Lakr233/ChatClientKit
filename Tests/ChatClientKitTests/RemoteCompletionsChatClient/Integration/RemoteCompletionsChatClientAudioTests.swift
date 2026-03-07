//
//  RemoteCompletionsChatClientAudioTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import Testing

struct RemoteCompletionsChatClientAudioTests {
    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Non-streaming chat completion with audio input`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let audioBase64 = TestHelpers.createTestAudioBase64(format: "wav")

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("What is in this audio?"),
                .audioBase64(audioBase64, format: "wav"),
            ])),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        #expect(content.isEmpty == false)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Streaming chat completion with audio input`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let audioBase64 = TestHelpers.createTestAudioBase64(format: "wav")

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("Transcribe this audio."),
                .audioBase64(audioBase64, format: "wav"),
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

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with audio and text`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let audioBase64 = TestHelpers.createTestAudioBase64(format: "wav")

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("What language is spoken in this audio?"),
                .audioBase64(audioBase64, format: "wav"),
            ])),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        #expect(content.isEmpty == false)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Chat completion with audio in conversation`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let audioBase64 = TestHelpers.createTestAudioBase64(format: "wav")

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("Listen to this audio."),
                .audioBase64(audioBase64, format: "wav"),
            ])),
            .assistant(content: .text("I've processed the audio.")),
            .user(content: .text("What did you hear?")),
        ])

        let response: ChatResponse = try await client.chat(body: request)

        let content = response.text
        #expect(content.isEmpty == false)
    }

    @Test(.enabled(if: TestHelpers.isOpenRouterAPIKeyConfigured))
    func `Streaming chat completion with audio and image`() async throws {
        let client = TestHelpers.makeOpenRouterClient()

        let audioBase64 = TestHelpers.createTestAudioBase64(format: "wav")
        let imageURL = TestHelpers.createTestImageDataURL()

        let request = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("I'm sending you both an audio and an image. Describe what you see and hear."),
                .audioBase64(audioBase64, format: "wav"),
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
}
