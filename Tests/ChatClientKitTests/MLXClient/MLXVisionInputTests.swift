@testable import ChatClientKit
import CoreImage
import Foundation
import MLXLMCommon
import MLXVLM
import Testing

struct MLXVisionInputTests {
    @Test
    func `Vision-enabled text requests do not contain image frames`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let input = try client.userInput(body: .init(messages: [
            .system(content: .text("Answer briefly.")),
            .user(content: .text("Hello")),
        ]))

        let messages = try chatMessages(from: input)

        #expect(messages.map(\.content) == ["Answer briefly.", "Hello"])
        #expect(messages.allSatisfy { $0.images.isEmpty })
        #expect(input.images.isEmpty)
        #expect(try imagePlaceholderCount(in: input) == 0)
    }

    @Test
    func `Multipart content keeps its image and text in one message`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let imageURL = TestHelpers.createTestImageDataURL()
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([
                .text("Describe this image."),
                .imageURL(imageURL),
                .text("Be concise."),
            ])),
        ]))

        let messages = try chatMessages(from: input)
        let message = try #require(messages.first)

        #expect(messages.count == 1)
        #expect(message.content == "Describe this image.\nBe concise.")
        #expect(message.images.count == 1)
        #expect(input.images.count == 1)
        #expect(try imagePlaceholderCount(in: input) == input.images.count)
    }

    @Test
    func `Image-only messages retain their placeholder before a text question`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let imageURL = TestHelpers.createTestImageDataURL()
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([.imageURL(imageURL)])),
            .user(content: .text("What is in the image?")),
        ]))

        let messages = try chatMessages(from: input)

        try #require(messages.count == 2)
        #expect(messages[0].content.isEmpty)
        #expect(messages[0].images.count == 1)
        #expect(messages[1].content == "What is in the image?")
        #expect(messages[1].images.isEmpty)
        #expect(try imagePlaceholderCount(in: input) == 1)
    }

    @Test
    func `Multiple image turns preserve frame order across text follow-ups`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let firstImage = TestHelpers.createTestImageDataURL(width: 80, height: 80)
        let secondImage = TestHelpers.createTestImageDataURL(width: 120, height: 80)
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([.imageURL(firstImage), .text("First image")])),
            .assistant(content: .text("It is red.")),
            .user(content: .parts([.text("Compare this one"), .imageURL(secondImage)])),
            .assistant(content: .text("It is wider.")),
            .user(content: .text("Summarize the differences.")),
        ]))

        let messages = try chatMessages(from: input)

        try #require(messages.count == 5)
        #expect(messages[0].images.count == 1)
        #expect(messages[2].images.count == 1)
        #expect(messages[4].images.isEmpty)
        try #require(input.images.count == 2)
        #expect(try input.images[0].asCIImage().extent.width == 80)
        #expect(try input.images[1].asCIImage().extent.width == 120)
        #expect(try imagePlaceholderCount(in: input) == input.images.count)
    }

    @Test
    func `Two images in one message produce two vision placeholders`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let imageURL = TestHelpers.createTestImageDataURL()
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([
                .text("Compare these images."),
                .imageURL(imageURL),
                .imageURL(imageURL),
            ])),
        ]))

        let messages = try chatMessages(from: input)

        try #require(messages.count == 1)
        #expect(messages[0].images.count == 2)
        #expect(input.images.count == 2)
        #expect(try imagePlaceholderCount(in: input) == 2)
    }

    @Test
    func `Vision message rendering preserves tool-call IDs and structured arguments`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/model"),
            preferredKind: .vlm
        )
        let imageURL = TestHelpers.createTestImageDataURL()
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([.imageURL(imageURL), .text("Look this up.")])),
            .assistant(
                content: .text("Checking."),
                toolCalls: [.init(
                    id: "call-1",
                    function: .init(name: "lookup", arguments: #"{"query":"red rectangle"}"#)
                )]
            ),
            .tool(content: .text("A red rectangle"), toolCallID: "call-1"),
            .user(content: .text("Summarize.")),
        ]))

        let messages = Qwen3VLMessageGenerator().generate(from: input)
        try #require(messages.count == 4)
        let calls = try #require(messages[1]["tool_calls"] as? [[String: any Sendable]])
        let function = try #require(calls.first?["function"] as? [String: any Sendable])
        let arguments = try #require(function["arguments"] as? [String: any Sendable])

        #expect(calls.first?["id"] as? String == "call-1")
        #expect(function["name"] as? String == "lookup")
        #expect(arguments["query"] as? String == "red rectangle")
        #expect(messages[2]["tool_call_id"] as? String == "call-1")
        #expect(messages[2]["name"] as? String == "lookup")
        #expect(try imagePlaceholderCount(in: input) == 1)
    }

    @Test
    func `Text-only model profiles discard images without discarding multipart text`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(url: URL(fileURLWithPath: "/tmp/model"))
        let imageURL = TestHelpers.createTestImageDataURL()
        let input = try client.userInput(body: .init(messages: [
            .user(content: .parts([
                .text("Use the existing description."),
                .imageURL(imageURL),
                .text("Answer briefly."),
            ])),
        ]))

        let messages = try chatMessages(from: input)

        try #require(messages.count == 1)
        #expect(messages[0].content == "Use the existing description.\nAnswer briefly.")
        #expect(messages[0].images.isEmpty)
        #expect(input.images.isEmpty)
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
    private func chatMessages(from input: UserInput) throws -> [Chat.Message] {
        guard case let .chat(messages) = input.prompt else {
            throw MLXVisionInputTestError.expectedStructuredChat
        }
        return messages
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
    private func imagePlaceholderCount(in input: UserInput) throws -> Int {
        var count = 0
        for message in Qwen3VLMessageGenerator().generate(from: input) {
            let parts = try #require(message["content"] as? [[String: String]])
            count += parts.filter { $0["type"] == "image" }.count
        }
        return count
    }
}

private enum MLXVisionInputTestError: Error {
    case expectedStructuredChat
}
