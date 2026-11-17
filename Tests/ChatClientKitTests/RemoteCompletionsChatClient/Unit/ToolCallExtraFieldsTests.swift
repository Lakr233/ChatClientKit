//
//  ToolCallExtraFieldsTests.swift
//  ChatClientKitTests
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

/// Provider-specific tool-call fields, such as Gemini's
/// `extra_content.google.thought_signature`, must survive parsing and be
/// echoed back unchanged on the follow-up request.
struct ToolCallExtraFieldsTests {
    static let signature = "CsQBAXLI2nw+test/signature=="
    static let extraContent: [String: AnyCodingValue] = [
        "extra_content": ["google": ["thought_signature": .string(signature)]],
    ]

    @Test
    func `Streamed tool call keeps provider extra fields`() async throws {
        let eventFactory = MockCompletionsEventSourceFactory()
        let part1 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"foo","arguments":"{\"value\":"},"extra_content":{"google":{"thought_signature":"\#(Self.signature)"}}}]}}]}"#
        let part2 = #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"42}"}}]}}]}"#
        let part3 = #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","type":"function","function":{"name":"bar","arguments":"{}"}}]}}]}"#
        eventFactory.recordedEvents = [
            .open,
            .event(CompletionsTestEvent(data: part1)),
            .event(CompletionsTestEvent(data: part2)),
            .event(CompletionsTestEvent(data: part3)),
            .closed,
        ]

        let client = makeClient(eventFactory: eventFactory)
        let stream = try await client.streamingChat(body: ChatRequestBody(messages: [.user(content: .text("Hi"))]))
        var calls: [ToolRequest] = []
        for try await chunk in stream {
            if let call = chunk.toolValue { calls.append(call) }
        }

        #expect(calls.count == 2)
        let first = try #require(calls.first)
        #expect(first.id == "call_1")
        #expect(first.args == #"{"value":42}"#)
        #expect(first.extraFields == Self.extraContent)
        // Gemini signs only the first call of a step; the next one stays clean.
        #expect(calls.last?.extraFields == nil)
    }

    @Test
    func `Non-streamed tool call keeps provider extra fields`() throws {
        let json = #"{"choices":[{"message":{"tool_calls":[{"id":"call_1","type":"function","function":{"name":"foo","arguments":"{}"},"extra_content":{"google":{"thought_signature":"\#(Self.signature)"}}}]}}]}"#
        let chunks = try RemoteCompletionsChatResponseDecoder().decodeResponse(from: Data(json.utf8))
        let call = try #require(chunks.compactMap(\.toolValue).first)
        #expect(call.extraFields == Self.extraContent)
    }

    @Test
    func `Follow-up request echoes provider extra fields unchanged`() throws {
        let request = ToolRequest(id: "call_1", name: "foo", args: "{}", extraFields: Self.extraContent)
        let body = ChatRequestBody(messages: [
            .user(content: .text("Hi")),
            .assistant(toolCalls: [
                .init(
                    id: request.id,
                    function: .init(name: request.name, arguments: request.args),
                    extraFields: request.extraFields
                ),
            ]),
            .tool(content: .text("ok"), toolCallID: request.id),
        ])

        let urlRequest = try makeClient().makeURLRequest(body: body)
        let bodyData = try #require(urlRequest.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let toolCall = try #require((assistant["tool_calls"] as? [[String: Any]])?.first)
        let extra = try #require(toolCall["extra_content"] as? [String: Any])
        let google = try #require(extra["google"] as? [String: Any])

        #expect(google["thought_signature"] as? String == Self.signature)
        #expect(toolCall["id"] as? String == "call_1")
        #expect(toolCall["type"] as? String == "function")
    }

    @Test
    func `Tool call without extra fields encodes exactly as before`() throws {
        let call = ChatRequestBody.Message.ToolCall(
            id: "call_1",
            function: .init(name: "foo", arguments: #"{"value":42}"#)
        )
        let legacy = LegacyToolCall(
            id: "call_1",
            function: .init(name: "foo", arguments: #"{"value":42}"#)
        )
        // Compare in the form requests are sent: key order is unspecified
        // without sortedKeys.
        let encoder = JSONEncoder.stableRequestEncoder
        let callData = try encoder.encode(call)
        let legacyData = try encoder.encode(legacy)
        #expect(callData == legacyData)

        let noArguments = ChatRequestBody.Message.ToolCall(id: "call_2", function: .init(name: "bar"))
        let legacyNoArguments = LegacyToolCall(id: "call_2", function: .init(name: "bar", arguments: nil))
        let noArgumentsData = try encoder.encode(noArguments)
        let legacyNoArgumentsData = try encoder.encode(legacyNoArguments)
        #expect(noArgumentsData == legacyNoArgumentsData)

        let empty = ChatRequestBody.Message.ToolCall(id: "call_1", function: .init(name: "foo"), extraFields: [:])
        #expect(empty.extraFields == nil)
    }

    @Test
    func `Stored ToolRequest JSON omits extra fields`() throws {
        let plain = ToolRequest(id: "call_1", name: "foo", args: "{}")
        let signed = ToolRequest(id: "call_1", name: "foo", args: "{}", extraFields: Self.extraContent)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let signedData = try encoder.encode(signed)
        let plainData = try encoder.encode(plain)
        #expect(signedData == plainData)

        let object = try #require(JSONSerialization.jsonObject(with: signedData) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "args"])

        let decoded = try JSONDecoder().decode(ToolRequest.self, from: signedData)
        #expect(decoded == plain)
        #expect(decoded.extraFields == nil)
    }

    @Test
    func `Argument repair and request normalization keep extra fields`() {
        let repaired = ToolCallArgumentRepair.normalize(
            request: ToolRequest(id: "call_1", name: "foo", args: "", extraFields: Self.extraContent),
            using: nil
        )
        #expect(repaired.args == "{}")
        #expect(repaired.extraFields == Self.extraContent)

        let calls = ToolCallArgumentRepair.normalize(
            toolCalls: [.init(id: "call_1", function: .init(name: "foo", arguments: ""), extraFields: Self.extraContent)],
            using: nil
        )
        #expect(calls?.first?.extraFields == Self.extraContent)

        let normalized = ChatRequest.normalizeToolCalls([
            .init(id: " call_1 ", function: .init(name: "foo", arguments: "{}"), extraFields: Self.extraContent),
        ])
        #expect(normalized?.first?.extraFields == Self.extraContent)
    }

    private func makeClient(
        eventFactory: MockCompletionsEventSourceFactory = MockCompletionsEventSourceFactory()
    ) -> RemoteCompletionsChatClient {
        let dependencies = RemoteChatClientDependencies(
            session: MockCompletionsURLSession(result: .failure(CompletionsTestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer()
        )
        return RemoteCompletionsChatClient(
            model: "gemini-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: "",
            dependencies: dependencies
        )
    }
}

/// Mirror of the tool-call payload before extra fields existed; its
/// synthesized encoding is the wire format other providers already accept.
private struct LegacyToolCall: Encodable {
    struct Function: Encodable {
        let name: String
        let arguments: String?
    }

    let id: String
    let type = "function"
    let function: Function
}
