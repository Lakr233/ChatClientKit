//
//  ResponsesImageInputEncodingTests.swift
//  ChatClientKitTests
//
//  Regression coverage for https://github.com/Lakr233/FlowDown/issues/248
//  The Responses API takes `input_image` parts in the flat form
//  `{"type": "input_image", "image_url": "<url>", "detail": "auto"}`,
//  not the nested `image_url: {url, detail}` object Chat Completions uses.
//

@testable import ChatClientKit
import Foundation
import Testing

struct ResponsesImageInputEncodingTests {
    private let imageURL = URL(string: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    @Test
    func `Image part encodes a flat image_url string with auto detail by default`() throws {
        let part = try encodedImagePart(detail: nil)

        #expect(part["type"] as? String == "input_image")
        let encodedURL = try #require(part["image_url"] as? String)
        #expect(encodedURL == imageURL.absoluteString)
        #expect(part["detail"] as? String == "auto")
        #expect(part["url"] == nil)
    }

    @Test
    func `Image part encodes an explicit detail next to the image_url string`() throws {
        let part = try encodedImagePart(detail: .high)

        #expect(part["type"] as? String == "input_image")
        let encodedURL = try #require(part["image_url"] as? String)
        #expect(encodedURL == imageURL.absoluteString)
        #expect(part["detail"] as? String == "high")
    }

    private func encodedImagePart(
        detail: ChatRequestBody.Message.ContentPart.ImageDetail?
    ) throws -> [String: Any] {
        let chatBody = ChatRequestBody(messages: [
            .user(content: .parts([
                .text("describe this"),
                .imageURL(imageURL, detail: detail),
            ])),
        ])
        let body = ResponsesRequestTransformer().makeRequestBody(
            from: chatBody,
            model: "gpt-resp",
            stream: false
        )
        let data = try JSONEncoder.stableRequestEncoder.encode(body)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let input = try #require(json["input"] as? [[String: Any]])
        let message = try #require(input.first { $0["role"] as? String == "user" })
        let content = try #require(message["content"] as? [[String: Any]])
        return try #require(content.first { $0["type"] as? String == "input_image" })
    }
}
