//
//  ParallelToolCallStreamingTests.swift
//  ChatClientKitTests
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

/// Parallel tool calls in one chat-completions stream must come out as
/// separate calls whatever numbering the server uses. Gemini's
/// OpenAI-compatible endpoint sends each call whole in its own delta and
/// leaves out `tool_calls[].index`; other servers send index 0 for every
/// call and tell them apart only by `id`.
struct ParallelToolCallStreamingTests {
    static let signature = "CsQBAXLI2nw+test/signature=="

    @Test
    func `Gemini calls without index stay apart`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"id":"function-call-1","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"Singapore news\",\"reason\":\"latest\"}"},"extra_content":{"google":{"thought_signature":"\#(Self.signature)"}}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"role":"assistant","tool_calls":[{"id":"function-call-2","type":"function","function":{"name":"scrape_web_page","arguments":"{\"reason\":\"read\",\"url\":\"https://www.gov.sg\"}"}}]},"finish_reason":"stop"}]}"#,
        ])

        #expect(calls.map(\.name) == ["web_search", "scrape_web_page"])
        #expect(calls.map(\.id) == ["function-call-1", "function-call-2"])
        #expect(calls.first?.args == #"{"query":"Singapore news","reason":"latest"}"#)
        #expect(calls.last?.args == #"{"reason":"read","url":"https://www.gov.sg"}"#)
        // Gemini signs only the first call of a step.
        #expect(calls.first?.extraFields == [
            "extra_content": ["google": ["thought_signature": .string(Self.signature)]],
        ])
        #expect(calls.last?.extraFields == nil)
    }

    @Test
    func `Calls of the same tool without index or id stay apart`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"id":"","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"type":"function","function":{"name":"web_search","arguments":"{\"query\":\"b\"}"}}]}}]}"#,
        ])

        #expect(calls.map(\.name) == ["web_search", "web_search"])
        #expect(calls.map(\.args) == [#"{"query":"a"}"#, #"{"query":"b"}"#])
        #expect(calls[0].id != calls[1].id)
    }

    @Test
    func `Calls sharing index zero with distinct ids stay apart`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"web_search","arguments":"{\"query\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_b","type":"function","function":{"name":"web_search","arguments":"{\"query\":\"b\"}"}}]}}]}"#,
        ])

        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls.map(\.name) == ["web_search", "web_search"])
        #expect(calls.map(\.args) == [#"{"query":"a"}"#, #"{"query":"b"}"#])
    }

    @Test
    func `Several whole calls in one delta stay apart`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"id":"call_a","type":"function","function":{"name":"web_search","arguments":"{}"}},{"id":"call_b","type":"function","function":{"name":"scrape_web_page","arguments":"{\"url\":\"u\"}"}}]}}]}"#,
        ])

        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls.map(\.name) == ["web_search", "scrape_web_page"])
        #expect(calls.map(\.args) == ["{}", #"{"url":"u"}"#])
    }

    @Test
    func `OpenAI indexed fragments still join per call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"role":"assistant","tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"web_search","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\"a\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_b","type":"function","function":{"name":"scrape_web_page","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"url\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"arguments":"\"u\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.map(\.id) == ["call_a", "call_b"])
        #expect(calls.map(\.name) == ["web_search", "scrape_web_page"])
        #expect(calls.map(\.args) == [#"{"query":"a"}"#, #"{"url":"u"}"#])
    }

    @Test
    func `Fragments repeating their id join one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"web_search","arguments":"{\"query\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"arguments":"\"a\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_a")
        #expect(calls.first?.name == "web_search")
        #expect(calls.first?.args == #"{"query":"a"}"#)
    }

    @Test
    func `Unindexed argument fragments join the current call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"id":"call_a","type":"function","function":{"name":"web_search","arguments":"{\"query\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"function":{"arguments":"\"a\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_a")
        #expect(calls.first?.args == #"{"query":"a"}"#)
    }

    private func collectCalls(from payloads: [String]) async throws -> [ToolRequest] {
        let eventFactory = MockCompletionsEventSourceFactory()
        var events: [EventSource.EventType] = [.open]
        for payload in payloads + ["[DONE]"] {
            events.append(.event(CompletionsTestEvent(data: payload)))
        }
        events.append(.closed)
        eventFactory.recordedEvents = events

        let dependencies = RemoteChatClientDependencies(
            session: MockCompletionsURLSession(result: .failure(CompletionsTestError())),
            eventSourceFactory: eventFactory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer()
        )
        let client = RemoteCompletionsChatClient(
            model: "gemini-test",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: "",
            dependencies: dependencies
        )

        let stream = try await client.streamingChat(body: ChatRequestBody(messages: [.user(content: .text("Hi"))]))
        var calls: [ToolRequest] = []
        for try await chunk in stream {
            if let call = chunk.toolValue { calls.append(call) }
        }
        return calls
    }
}
