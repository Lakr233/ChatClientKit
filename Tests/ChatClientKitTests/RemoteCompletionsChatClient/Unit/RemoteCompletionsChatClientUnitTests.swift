//
//  RemoteCompletionsChatClientUnitTests.swift
//  ChatClientKitTests
//
//  Created by Test Suite on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

@Suite("RemoteCompletionsChatClient Unit Tests")
struct RemoteCompletionsChatClientUnitTests {
    @Test("URL request omits Authorization header when API key is empty")
    func makeURLRequest_withoutApiKey_omitsAuthorizationHeader() throws {
        let session = MockURLSession(result: .failure(TestError()))

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteCompletionsChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: "",
            additionalHeaders: ["cf-aig-authorization": "Bearer gateway-token"],
            dependencies: dependencies,
        )

        let request = try client.makeURLRequest(body: ChatRequestBody(messages: [.user(content: .text("Hello"))]))

        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "cf-aig-authorization") == "Bearer gateway-token")
    }

    @Test("Chat completion request when server returns error throws decoded error")
    func chatCompletionRequest_whenServerReturnsError_throwsDecodedError() async throws {
        let errorJSON: [String: Any] = [
            "status": 401,
            "error": "unauthorized",
            "message": "Invalid API key",
        ]
        let responseData = try JSONSerialization.data(withJSONObject: errorJSON)
        let response = try URLResponse(
            url: #require(URL(string: "https://example.com/v1/chat/completions")),
            mimeType: "application/json",
            expectedContentLength: responseData.count,
            textEncodingName: nil,
        )
        let session = MockCompletionsURLSession(result: .success((responseData, response)))

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteCompletionsChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        do {
            let response = try await client.chat(body: request)
            if client.collectedErrors != nil { throw NSError() }
            Issue.record("Expected error to be thrown: \(response)")
        } catch {
            // good
        }
    }

    @Test("Streaming chat completion request emits reasoning and tool calls")
    func streamingChatCompletionRequest_emitsReasoningAndToolCalls() async throws {
        let session = MockCompletionsURLSession(result: .failure(CompletionsTestError()))
        let eventFactory = MockCompletionsEventSourceFactory()

        let reasoningChunk = #"{"choices":[{"delta":{"content":"<think>internal</think>Visible"}}]}"#
        let toolChunkPart1 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"foo","arguments":"{\"value\":"}}]}}]}"#
        let toolChunkPart2 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"42}"}}]}}]}"#

        eventFactory.recordedEvents = [
            .open,
            .event(CompletionsTestEvent(data: reasoningChunk)),
            .event(CompletionsTestEvent(data: toolChunkPart1)),
            .event(CompletionsTestEvent(data: toolChunkPart2)),
            .closed,
        ]

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteCompletionsChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        let stream = try await client.streamingChat(body: request)

        var received: [ChatResponseChunk] = []
        for try await element in stream {
            received.append(element)
        }

        let reasoningDelta = received.compactMap(\.reasoningValue).first
        #expect(reasoningDelta == "internal")

        let contentDelta = received.compactMap(\.textValue).last
        #expect(contentDelta == "Visible")

        let toolCall = received.compactMap(\.toolValue).first
        #expect(toolCall?.name == "foo")
        #expect(toolCall?.args == "{\"value\":42}")

        let capturedRequest = try #require(eventFactory.lastRequest)
        let bodyData = try #require(capturedRequest.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["stream"] as? Bool == true)
    }

    @Test("Streaming chat completion forwards explicit reasoning field")
    func streamingChatCompletionRequest_emitsExplicitReasoningField() async throws {
        let session = MockCompletionsURLSession(result: .failure(CompletionsTestError()))
        let eventFactory = MockCompletionsEventSourceFactory()

        let reasoningChunk = #"{"choices":[{"delta":{"reasoning":"plan","content":"Visible answer"}}]}"#

        eventFactory.recordedEvents = [
            .open,
            .event(CompletionsTestEvent(data: reasoningChunk)),
            .closed,
        ]

        let dependencies = RemoteChatClientDependencies(
            session: session,
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteCompletionsChatClient(
            model: "gpt-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let request = ChatRequestBody(messages: [
            .user(content: .text("Hello")),
        ])

        let stream = try await client.streamingChat(body: request)

        var received: [ChatResponseChunk] = []
        for try await element in stream {
            received.append(element)
        }

        let reasoningDelta = received.compactMap(\.reasoningValue).first
        #expect(reasoningDelta == "plan")

        let contentDelta = received.compactMap(\.textValue).first
        #expect(contentDelta == "Visible answer")
    }
}

// MARK: - Test Doubles

class MockCompletionsURLSession: URLSessioning, @unchecked Sendable {
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

class MockCompletionsEventSourceFactory: EventSourceProducing, @unchecked Sendable {
    var recordedEvents: [EventSource.EventType] = []
    private(set) var lastRequest: URLRequest?

    func makeDataTask(for request: URLRequest) -> EventStreamTask {
        lastRequest = request
        return MockCompletionsEventStreamTask(recordedEvents: recordedEvents)
    }
}

struct MockCompletionsEventStreamTask: EventStreamTask {
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

struct CompletionsTestEvent: EVEvent {
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
        time: String? = nil,
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.other = other
        self.time = time
    }
}

struct CompletionsTestError: Swift.Error {}
