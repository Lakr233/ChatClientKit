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

@Suite("RemoteResponsesClient Unit Tests")
struct RemoteResponsesClientUnitTests {
    @Test("Builds responses payload from chat request")
    func makeURLRequest_buildsResponsesPayload() throws {
        let session = MockURLSession(result: .failure(TestError()))
        let dependencies = RemoteResponsesClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
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

        let request = try client.makeURLRequest(from: body, stream: false)
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
        let dependencies = RemoteResponsesClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
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

        let request = try client.makeURLRequest(from: body, stream: false)
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
        let dependencies = RemoteResponsesClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
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

        let request = try client.makeURLRequest(from: body, stream: false)
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

    @Test("Decodes responses object into chat response body")
    func chatCompletionRequest_decodesResponsesPayload() async throws {
        let responseJSON: [String: Any] = [
            "id": "resp_1",
            "created_at": 1234,
            "model": "gpt-resp",
            "output": [
                [
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        [
                            "type": "output_text",
                            "text": "Answer",
                        ],
                    ],
                ],
                [
                    "type": "function_call",
                    "id": "call_1",
                    "name": "do_thing",
                    "arguments": "{\"value\":42}",
                ],
            ],
        ]
        let responseData = try JSONSerialization.data(withJSONObject: responseJSON)
        let response = URLResponse(
            url: URL(string: "https://example.com/v1/responses")!,
            mimeType: "application/json",
            expectedContentLength: responseData.count,
            textEncodingName: nil,
        )
        let session = MockURLSession(result: .success((responseData, response)))
        let dependencies = RemoteResponsesClientDependencies(
            session: session,
            eventSourceFactory: DefaultEventSourceFactory(),
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let result = try await client.responsesRequest(body: .init(messages: [.user(content: .text("hi"))]))

        #expect(result.model == "gpt-resp")
        let choice = try #require(result.choices.first)
        #expect(choice.message.content == "Answer")
        let toolCall = try #require(choice.message.toolCalls?.first)
        #expect(toolCall.function.name == "do_thing")
        #expect(toolCall.function.argumentsRaw == "{\"value\":42}")
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
        #expect(result.choices.count == 1)
        let choice = try #require(result.choices.first)
        #expect(choice.finishReason == "tool_calls")
        let toolCall = try #require(choice.message.toolCalls?.first)
        #expect(toolCall.id == "call_only")
        #expect(toolCall.function.name == "only_tool")
        #expect(toolCall.function.argumentsRaw == "{\"ready\":true}")
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
        #expect(result.choices.count == 2)

        let first = try #require(result.choices.first)
        #expect(first.message.content == "First")
        let firstCall = try #require(first.message.toolCalls?.first)
        #expect(firstCall.function.name == "do_first")

        let second = try #require(result.choices.last)
        #expect(second.message.content == "Second")
        let secondCall = try #require(second.message.toolCalls?.first)
        #expect(secondCall.function.name == "do_second")
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
        let choice = try #require(result.choices.first)
        let content = try #require(choice.message.content)
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
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var received: [ChatServiceStreamObject] = []
        for try await item in stream {
            received.append(item)
        }

        let chunks = received.compactMap { object -> ChatCompletionChunk? in
            guard case let .chatCompletionChunk(chunk) = object else { return nil }
            return chunk
        }
        let firstContent = chunks.first?.choices.first?.delta
        #expect(firstContent?.content == "Hi")
        #expect(firstContent?.role == "assistant")
        let lastFinishReason = chunks.last?.choices.first?.finishReason
        #expect(lastFinishReason == "tool_calls")

        let toolCall = received.compactMap { object -> ToolCallRequest? in
            guard case let .tool(call) = object else { return nil }
            return call
        }.first
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
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var chunks: [ChatCompletionChunk] = []
        for try await item in stream {
            if case let .chatCompletionChunk(chunk) = item {
                chunks.append(chunk)
            }
        }

        #expect(chunks.count == 2)
        #expect(chunks[0].choices.first?.delta.content == "Hi")
        #expect(chunks[1].choices.first?.delta.content == nil)
        #expect(chunks[1].choices.first?.finishReason == "stop")
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
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var chunks: [ChatCompletionChunk] = []
        for try await item in stream {
            if case let .chatCompletionChunk(chunk) = item {
                chunks.append(chunk)
            }
        }

        #expect(chunks.count == 2)
        #expect(chunks[0].choices.first?.delta.content == "Hi")
        #expect(chunks[1].choices.first?.delta.content == nil)
        #expect(chunks[1].choices.first?.finishReason == "stop")
    }

    @Test("Streaming emits done text when no deltas")
    func streamingChatCompletion_emitsDoneText() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.output_text.done","item_id":"msg_1","output_index":0,"text":"Hola"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var chunks: [ChatCompletionChunk] = []
        for try await item in stream {
            if case let .chatCompletionChunk(chunk) = item {
                chunks.append(chunk)
            }
        }

        #expect(chunks.count == 2)
        #expect(chunks.first?.choices.first?.delta.content == "Hola")
        #expect(chunks.first?.choices.first?.finishReason == nil)
        #expect(chunks.last?.choices.first?.delta.content == nil)
        #expect(chunks.last?.choices.first?.finishReason == "stop")
    }

    @Test("Streaming emits error when response fails")
    func streamingChatCompletion_handlesFailedEvent() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.failed","response":{"status":"failed","error":{"message":"boom"}}}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
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
        let choice = try #require(result.choices.first)
        #expect(choice.finishReason == "refusal")
        #expect(choice.message.content == "I cannot help with that.")
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
        #expect(stopResponse.choices.first?.finishReason == "stop")

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
        #expect(toolResponse.choices.first?.finishReason == "tool_calls")
    }

    @Test("Streaming emits refusal content with refusal finish reason")
    func streamingChatCompletion_refusalDoneIncludesContent() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.refusal.done","item_id":"msg_1","output_index":0,"refusal":"nope"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var chunks: [ChatCompletionChunk] = []
        for try await object in stream {
            if case let .chatCompletionChunk(chunk) = object {
                chunks.append(chunk)
            }
        }

        let refusalChunk = try #require(chunks.first)
        #expect(refusalChunk.choices.first?.delta.refusal == "nope")
        #expect(refusalChunk.choices.first?.finishReason == "refusal")
    }

    @Test("Streaming emits reasoning content from reasoning_text.done")
    func streamingChatCompletion_reasoningDoneIncludesText() async throws {
        let events: [EventSource.EventType] = [
            .event(TestEvent(data: #"{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_1","type":"message","role":"assistant","content":[]}}"#)),
            .event(TestEvent(data: #"{"type":"response.reasoning_text.done","item_id":"msg_1","output_index":0,"text":"final chain"}"#)),
            .closed,
        ]
        let eventFactory = MockEventSourceFactory(recordedEvents: events)
        let dependencies = RemoteResponsesClientDependencies(
            session: MockURLSession(result: .failure(TestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: ReasoningContentParser(),
            requestSanitizer: ChatRequestSanitizer(),
        )

        let client = RemoteResponsesClient(
            model: "gpt-resp",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: TestHelpers.requireAPIKey(),
            dependencies: dependencies,
        )

        let stream = try await client.streamingResponsesRequest(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
        )

        var reasoningContent: String?
        for try await item in stream {
            if case let .chatCompletionChunk(chunk) = item {
                if let reasoning = chunk.choices.first?.delta.reasoningContent, !reasoning.isEmpty {
                    reasoningContent = reasoning
                    break
                }
            }
        }

        #expect(reasoningContent == "final chain")
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
}

private struct TestError: Swift.Error {}
