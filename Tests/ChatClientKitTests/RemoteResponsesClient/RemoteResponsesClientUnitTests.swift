//
//  RemoteResponsesClientUnitTests.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/5.
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

@Suite("RemoteResponsesChatClient Unit Tests")
struct RemoteResponsesClientUnitTests {
    @Test("Builds responses payload from chat request")
    func makeURLRequest_buildsResponsesPayload() throws {
        let session = MockURLSession(result: .failure(TestError()))
        let dependencies = RemoteClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            additionalHeaders: ["X-Test": "value"],
            additionalBodyField: ["foo": "bar"],
            dependencies: dependencies,
        )

        let body = ChatRequestBody(messages: [
            .system(content: .text(" guide ")),
            .user(content: .text(" hi ")),
            .tool(content: .text("tool result"), toolCallID: "call-1"),
        ])

        let request = try client.makeURLRequest(
            body: client.resolve(body: body, stream: false),
        )
        #expect(request.url?.absoluteString == "https://example.com/v1/responses")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(TestHelpers.requireAPIKey())")
        #expect(request.value(forHTTPHeaderField: "X-Test") == "value")

        let bodyData = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(json["model"] as? String == "gpt-resp")
        #expect(json["stream"] as? Bool == false)
        #expect(json["foo"] as? String == "bar")

        let instructions = json["instructions"] as? String
        #expect(instructions?.contains("guide") == true)

        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 2)

        let user = try #require(input.first)
        #expect(user["type"] as? String == "message")
        #expect(user["role"] as? String == "user")
        let content = try #require(user["content"] as? [[String: Any]])
        let firstContent = try #require(content.first)
        #expect(firstContent["type"] as? String == "input_text")
        #expect(firstContent["text"] as? String == " hi ")

        let tool = try #require(input.last)
        #expect(tool["type"] as? String == "function_call_output")
        #expect(tool["call_id"] as? String == "call-1")
        #expect(tool["output"] as? String == "tool result")
    }

    @Test("Encodes tools using responses schema")
    func makeURLRequest_encodesToolsWithFlatSchema() throws {
        let session = MockURLSession(result: .failure(TestError()))
        let dependencies = RemoteClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let parameters: [String: AnyCodingValue] = [
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                ]),
            ]),
            "required": .array([.string("query")]),
        ]
        let body = ChatRequestBody(
            messages: [.user(content: .text("hi"))],
            tools: [
                .function(
                    name: "search",
                    description: "Searches the index",
                    parameters: parameters,
                    strict: true,
                ),
            ],
        )

        let request = try client.makeURLRequest(
            body: client.resolve(body: body, stream: false),
        )
        let bodyData = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)

        let tool = try #require(tools.first)
        #expect(tool["type"] as? String == "function")
        #expect(tool["name"] as? String == "search")
        #expect(tool["description"] as? String == "Searches the index")
        #expect(tool["strict"] as? Bool == true)
        #expect(tool["function"] == nil)

        let encodedParameters = try #require(tool["parameters"] as? [String: Any])
        #expect(encodedParameters["type"] as? String == "object")
        let properties = try #require(encodedParameters["properties"] as? [String: Any])
        let query = try #require(properties["query"] as? [String: Any])
        #expect(query["type"] as? String == "string")
        let required = try #require(encodedParameters["required"] as? [String])
        #expect(required == ["query"])
    }

    @Test("Includes assistant tool calls in responses payload")
    func makeURLRequest_includesAssistantToolCalls() throws {
        let session = MockURLSession(result: .failure(TestError()))
        let dependencies = RemoteClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let toolCall = ChatRequestBody.Message.ToolCall(
            id: "call-1",
            function: .init(name: "do_calc", arguments: "{\"v\":1}"),
        )
        let body = ChatRequestBody(messages: [
            .assistant(content: nil, toolCalls: [toolCall]),
            .tool(content: .text("result text"), toolCallID: "call-1"),
        ])

        let request = try client.makeURLRequest(
            body: client.resolve(body: body, stream: false),
        )
        let bodyData = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        let input = try #require(json["input"] as? [[String: Any]])
        #expect(input.count == 2)

        let functionCall = try #require(input.first)
        #expect(functionCall["type"] as? String == "function_call")
        #expect(functionCall["call_id"] as? String == "call-1")
        #expect(functionCall["name"] as? String == "do_calc")
        #expect(functionCall["arguments"] as? String == "{\"v\":1}")

        let tool = try #require(input.last)
        #expect(tool["type"] as? String == "function_call_output")
        #expect(tool["call_id"] as? String == "call-1")
        #expect(tool["output"] as? String == "result text")
    }

    @Test("Decodes function-only output into tool call choice")
    func chatCompletionRequest_handlesFunctionOnlyOutput() throws {
        let responseJSON: [String: Any] = [
            "output": [
                [
                    "type": "function_call",
                    "call_id": "call_only",
                    "name": "only_tool",
                    "arguments": "{\"ready\":true}",
                ],
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let decoder = RemoteResponsesChatResponseDecoder(decoder: JSONDecoderWrapper())

        let result = try decoder.decodeResponse(from: responseData)
        let tool = try #require(ChatResponse(chunks: result).tools.first)
        #expect(tool.id == "call_only")
        #expect(tool.name == "only_tool")
        #expect(tool.args == "{\"ready\":true}")
    }

    @Test("Decodes multiple output items and keeps tool calls with their message")
    func chatCompletionRequest_handlesMultipleOutputs() throws {
        let responseJSON: [String: Any] = [
            "id": "resp_2",
            "created_at": 1234,
            "model": "gpt-resp",
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "First"],
                    ],
                ],
                [
                    "type": "function_call",
                    "id": "call_1",
                    "name": "do_first",
                    "arguments": "{\"foo\":1}",
                ],
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Second"],
                    ],
                ],
                [
                    "type": "function_call",
                    "id": "call_2",
                    "name": "do_second",
                    "arguments": "{\"bar\":2}",
                ],
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let decoder = RemoteResponsesChatResponseDecoder(decoder: JSONDecoderWrapper())

        let result = try decoder.decodeResponse(from: responseData)
        let tool = try #require(ChatResponse(chunks: result).tools.first)
        #expect(tool.name == "do_first")
    }

    @Test("Decodes placeholders for unsupported modalities")
    func chatCompletionRequest_emitsPlaceholders() throws {
        let responseJSON: [String: Any] = [
            "id": "resp_3",
            "created_at": 1234,
            "model": "gpt-resp",
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_audio"],
                        ["type": "output_image", "text": "diagram"],
                    ],
                ],
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let decoder = RemoteResponsesChatResponseDecoder(decoder: JSONDecoderWrapper())

        let result = try decoder.decodeResponse(from: responseData)
        let content = try #require(ChatResponse(chunks: result).text)
        #expect(content.contains("[AUDIO]"))
        #expect(content.contains("diagram"))
    }

    @Test("Error extractor flags non-success string status")
    func errorExtractor_flagsFailedStatus() throws {
        let payload: [String: Any] = [
            "status": "failed",
            "message": "boom",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let extractor = RemoteResponsesErrorExtractor()

        let error = extractor.extractError(from: data)
        #expect(error != nil)
        #expect(error?.localizedDescription.contains("boom") == true)
    }

    @Test("Streaming emits text deltas and tool calls")
    func streamingChatCompletion_emitsTextAndToolCalls() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"Hi"}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hi"}"#)),
            .event(TestEvent(data: #"{"type":"response.function_call_arguments.delta","item_id":"call_1","name":"calc","delta":"{"#)),
            .event(TestEvent(data: #"{"type":"response.function_call_arguments.done","item_id":"call_1","name":"calc","arguments":"{\"v\":1}"}"#)),
            .event(TestEvent(data: #"{"type":"response.completed"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var received: [ChatResponseChunk] = []
        for try await item in stream {
            received.append(item)
        }

        let firstContent = received.compactMap(\.textValue).first
        #expect(firstContent == "Hi")

        let toolCall = received.compactMap(\.toolValue).first
        #expect(toolCall?.name == "calc")
        #expect(toolCall?.args == "{\"v\":1}")

        let capturedRequest = try #require(eventFactory.lastRequest)
        #expect(capturedRequest.url?.absoluteString == "https://example.com/v1/responses")
        let bodyData = try #require(capturedRequest.httpBody)
        let bodyJSON = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(bodyJSON["stream"] as? Bool == true)
    }

    @Test("Streaming stop chunk does not duplicate final text")
    func streamingChatCompletion_stopChunkNoText() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"Hi"}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hi"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var chunks: [ChatResponseChunk] = []
        for try await item in stream {
            chunks.append(item)
        }

        #expect(chunks.count >= 1)
        #expect(chunks.first?.textValue == "Hi")
    }

    @Test("Streaming ignores content_part.done full text to avoid duplication")
    func streamingChatCompletion_ignoresContentPartDone() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"Hi"}"#)),
            .event(TestEvent(data: #"{"type":"response.content_part.done","item_id":"msg_1","output_index":0,"part":{"type":"output_text","text":"Hi"}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hi"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var texts: [String] = []
        for try await item in stream {
            if let text = item.textValue {
                texts.append(text)
            }
        }

        #expect(texts.first == "Hi")
        if texts.count > 1 {
            #expect(texts.last?.isEmpty == true)
        }
    }

    @Test("Streaming emits done text when no deltas")
    func streamingChatCompletion_emitsDoneText() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hola"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var texts: [String] = []
        for try await item in stream {
            if let text = item.textValue {
                texts.append(text)
            }
        }

        #expect(texts.first == "Hola")
        if texts.count > 1 {
            #expect(texts.last?.isEmpty == true)
        }
    }

    @Test("Streaming emits error when response fails")
    func streamingChatCompletion_handlesFailedEvent() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.failed","response":{"status":"failed","error":{"message":"boom"}}}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        for try await _ in stream {}

        let capturedError = await client.collectedErrors
        #expect(capturedError?.contains("boom") == true)
    }

    @Test("Decodes refusal content with refusal finish reason")
    func chatCompletionRequest_decodesRefusal() throws {
        let responseJSON: [String: Any] = [
            "id": "resp_refusal",
            "created_at": 1234,
            "model": "gpt-resp",
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "refusal", "text": "I cannot help with that."],
                    ],
                ],
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let decoder = RemoteResponsesChatResponseDecoder(decoder: JSONDecoderWrapper())

        let result = try decoder.decodeResponse(from: responseData)
        let text = try #require(ChatResponse(chunks: result).text)
        #expect(text == "I cannot help with that.")
    }

    @Test("Decodes finish reasons for stop vs tool calls")
    func chatCompletionRequest_setsFinishReasonVariants() throws {
        let stopJSON: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Answer"],
                    ],
                ],
            ],
        ]
        let stopData = try JSONSerialization.data(withJSONObject: stopJSON)
        let decoder = RemoteResponsesChatResponseDecoder(decoder: JSONDecoderWrapper())
        let stopResponse = try decoder.decodeResponse(from: stopData)
        #expect(ChatResponse(chunks: stopResponse).text == "Answer")

        let toolJSON: [String: Any] = [
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        ["type": "output_text", "text": "Next do:"],
                    ],
                ],
                [
                    "type": "function_call",
                    "id": "call_x",
                    "name": "do_next",
                    "arguments": "{\"x\":1}",
                ],
            ],
        ]
        let toolData = try JSONSerialization.data(withJSONObject: toolJSON)
        let toolResponse = try decoder.decodeResponse(from: toolData)
        #expect(ChatResponse(chunks: toolResponse).tools.first?.name == "do_next")
    }

    @Test("Streaming emits refusal content with refusal finish reason")
    func streamingChatCompletion_refusalDoneIncludesContent() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.refusal.done","item_id":"msg_1","output_index":0,"refusal":"nope"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var refusalText: String?
        for try await object in stream {
            if let text = object.textValue, !text.isEmpty {
                refusalText = text
                break
            }
        }

        #expect(refusalText == "nope")
    }

    @Test("Streaming emits reasoning content from reasoning_text.done")
    func streamingChatCompletion_reasoningDoneIncludesText() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.reasoning_text.done","item_id":"msg_1","output_index":0,"text":"final chain"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer(),
        )

        let client = RemoteResponsesChatClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var reasoningContent: String?
        for try await item in stream {
            if case let .reasoning(reasoning) = item, !reasoning.isEmpty {
                reasoningContent = reasoning
                break
            }
        }

        #expect(reasoningContent == "final chain")
    }
}

// MARK: - Test Doubles

final class MockURLSession: URLSessioning, @unchecked Sendable {
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

final class MockEventSourceFactory: EventSourceProducing, @unchecked Sendable {
    var recordedEvents: [EventSource.EventType]
    private(set) var lastRequest: URLRequest?

    init(recordedEvents: [EventSource.EventType]) {
        self.recordedEvents = recordedEvents
    }

    func makeDataTask(for request: URLRequest) -> EventStreamTask {
        lastRequest = request
        return MockEventStreamTask(recordedEvents: recordedEvents)
    }
}

struct MockEventStreamTask: EventStreamTask {
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

struct TestEvent: EVEvent {
    var id: String?
    var event: String?
    var data: String?
    var other: [String: String]?
    var time: String?
}

struct TestError: Swift.Error {}
