//
//  RemoteChatClientUnitTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

@Suite("RemoteChatClient Unit Tests")
struct RemoteChatClientUnitTests {
    @Test("Chat completion request decodes reasoning and includes additional fields")
    func chatCompletionRequest_decodesReasoningAndIncludesAdditionalFields() async throws {
        let responseJSON: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "<think>internal</think>Final answer",
                    ],
                ],
            ],
            "created": 123,
            "model": "gpt-test",
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = URLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            mimeType: "application/json",
            expectedContentLength: responseData.count,
            textEncodingName: nil
        )
        let session = MockURLSession(result: .success((responseData, response)))

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: ReasoningContentParser()
        )

        let client = RemoteChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            additionalHeaders: ["X-Test": "value"],
            additionalBodyField: ["foo": "bar"],
            dependencies: dependencies
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        let result = try await client.chatCompletionRequest(body: request)

        #expect(result.model == "gpt-test")
        #expect(result.choices.count == 1)
        let choice = try #require(result.choices.first)
        #expect(choice.message.reasoningContent == "internal")
        #expect(choice.message.content == "Final answer")

        let madeRequest = try #require(session.lastRequest)
        #expect(madeRequest.url?.absoluteString == "https://example.com/v1/chat/completions")
        #expect(madeRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestHelpers.requireAPIKey())")
        #expect(madeRequest.value(forHTTPHeaderField: "X-Test") == "value")

        let bodyData = try #require(madeRequest.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["model"] as? String == "gpt-test")
        #expect(bodyJSON["stream"] as? Bool == false)
        #expect(bodyJSON["stream_options"] == nil)
        #expect(bodyJSON["foo"] as? String == "bar")
    }

    @Test("Chat completion builder convenience forwards through request DSL")
    func chatCompletion_builderForwardsThroughDSL() async throws {
        let responseJSON: [String: Any] = [
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "Answer",
                    ],
                ],
            ],
            "created": 456,
            "model": "gpt-test",
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = URLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            mimeType: "application/json",
            expectedContentLength: responseData.count,
            textEncodingName: nil
        )
        let session = MockURLSession(result: .success((responseData, response)))

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: ReasoningContentParser()
        )

        let client = RemoteChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies
        )

        let result = try await client.chatCompletion {
            ChatRequest.temperature(0.3)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("  sys "))
                ChatRequest.Message.user(content: .text(" hi "))
            }
        }

        #expect(result.model == "gpt-test")
        #expect(result.choices.first?.message.content == "Answer")

        let madeRequest = try #require(session.lastRequest)
        let bodyData = try #require(madeRequest.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["model"] as? String == "gpt-test")
        #expect(bodyJSON["temperature"] as? Double == 0.3)
        #expect(bodyJSON["messages"] is [[String: Any]])
    }

    @Test("Chat completion request when server returns error throws decoded error")
    func chatCompletionRequest_whenServerReturnsError_throwsDecodedError() async throws {
        let errorJSON: [String: Any] = [
            "status": 401,
            "error": "unauthorized",
            "message": "Invalid API key",
        ]
        let responseData = try JSONSerialization.data(withJSONObject: errorJSON)
        let response = URLResponse(
            url: URL(string: "https://example.com/v1/chat/completions")!,
            mimeType: "application/json",
            expectedContentLength: responseData.count,
            textEncodingName: nil
        )
        let session = MockURLSession(result: .success((responseData, response)))

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: ReasoningContentParser()
        )

        let client = RemoteChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        do {
            _ = try await client.chatCompletionRequest(body: request)
            Issue.record("Expected error to be thrown")
        } catch {
            // Expected error
            #expect(error.localizedDescription.contains("Invalid API key"))
        }
    }

    @Test("Streaming chat completion request emits reasoning and tool calls")
    func streamingChatCompletionRequest_emitsReasoningAndToolCalls() async throws {
        let session = MockURLSession(result: .failure(TestError()))
        let eventFactory = MockEventSourceFactory()

        let reasoningChunk = #"{"choices":[{"delta":{"content":"<think>internal</think>Visible"}}]}"#
        let toolChunkPart1 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"foo","arguments":"{\"value\":"}}]}}]}"#
        let toolChunkPart2 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"42}"}}]}}]}"#

        eventFactory.recordedEvents = [
            .open,
            .event(TestEvent(data: reasoningChunk)),
            .event(TestEvent(data: toolChunkPart1)),
            .event(TestEvent(data: toolChunkPart2)),
            .closed,
        ]

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: ReasoningContentParser()
        )

        let client = RemoteChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        let stream = try await client.streamingChatCompletionRequest(body: request)

        var received: [ChatServiceStreamObject] = []
        for try await element in stream {
            received.append(element)
        }

        let reasoningDelta = received.compactMap { object -> String? in
            guard case let .chatCompletionChunk(chunk) = object else { return nil }
            return chunk.choices.first?.delta.reasoningContent
        }.first
        #expect(reasoningDelta == "internal")

        let contentDelta = received.compactMap { object -> String? in
            guard case let .chatCompletionChunk(chunk) = object else { return nil }
            return chunk.choices.first?.delta.content
        }.last
        #expect(contentDelta == "Visible")

        let toolCall = received.compactMap { object -> ToolCallRequest? in
            if case let .tool(call) = object { return call }
            return nil
        }.first
        #expect(toolCall?.name == "foo")
        #expect(toolCall?.args == "{\"value\":42}")

        let capturedRequest = try #require(eventFactory.lastRequest)
        let bodyData = try #require(capturedRequest.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["stream"] as? Bool == true)
    }
}

// MARK: - Test Doubles

private final class MockURLSession: URLSessioning, @unchecked Sendable {
    var result: Result<(Data, URLResponse), Swift.Error>
    private(set) var lastRequest: URLRequest?

    init(result: Result<(Data, URLResponse), Swift.Error>) {
        self.result = result
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        return try result.get()
    }
}

private final class MockEventSourceFactory: EventSourceProducing, @unchecked Sendable {
    var recordedEvents: [EventSource.EventType] = []
    private(set) var lastRequest: URLRequest?

    func makeDataTask(for request: URLRequest) -> EventStreamTask {
        lastRequest = request
        return MockEventStreamTask(recordedEvents: recordedEvents)
    }
}

private struct MockEventStreamTask: EventStreamTask {
    let recordedEvents: [EventSource.EventType]

    func events() -> AsyncStream<EventSource.EventType> {
        AsyncStream { continuation in
            for event in recordedEvents {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }
}

private struct TestEvent: EVEvent {
    var id: String?
    var event: String?
    var data: String?
    var other: [String: String]?
    var time: String?

    init(
        id: String? = nil,
        event: String? = nil,
        data: String? = nil,
        other: [String: String]? = nil,
        time: String? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.other = other
        self.time = time
    }
}

private struct TestError: Swift.Error {}
