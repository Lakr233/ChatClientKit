//
//  OpenAICompatibleServerToolCallTests.swift
//  ChatClientKitTests
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

/// Streamed tool calls as local OpenAI-compatible servers really send them.
/// Each must come out as one call with its whole arguments, and parallel
/// calls must stay apart. The payloads are copied from the servers' output
/// (captured on an Apple Silicon Mac, Qwen3.5-0.8B-4bit, qwen3_coder tool
/// parser) or built from the code that writes their tool-call deltas.
struct OpenAICompatibleServerToolCallTests {
    // MARK: - Captured from real servers

    /// oMLX v0.8.1 (jundot/omlx, omlx/server.py `stream_chat_completion`):
    /// every call is parsed whole and sent in one delta carrying `index`,
    /// `id`, `type`, `name` and the full `arguments`; then an empty delta
    /// with `finish_reason: tool_calls`.
    @Test
    func `oMLX single call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"id":"chatcmpl-3fb21a19","object":"chat.completion.chunk","created":1795232943,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-3fb21a19","object":"chat.completion.chunk","created":1795232943,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            #"{"id":"chatcmpl-3fb21a19","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_90515e47","type":"function","function":{"name":"get_weather","arguments":"{\"city\": \"Tokyo\", \"unit\": \"celsius\"}"}}]}}]}"#,
            #"{"id":"chatcmpl-3fb21a19","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_90515e47")
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city": "Tokyo", "unit": "celsius"}"#)
    }

    /// oMLX v0.8.1 with `stream_options.include_usage`: a trailing usage
    /// chunk with empty `choices`.
    @Test
    func `oMLX call followed by usage chunk`() async throws {
        let calls = try await collectCalls(from: [
            #"{"id":"chatcmpl-796bcf34","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-796bcf34","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            #"{"id":"chatcmpl-796bcf34","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_5056b1bd","type":"function","function":{"name":"web_search","arguments":"{\"query\": \"latest Swift release 2026 date\"}"}}]}}]}"#,
            #"{"id":"chatcmpl-796bcf34","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"id":"chatcmpl-796bcf34","object":"chat.completion.chunk","created":1795232944,"model":"Qwen3.5-0.8B-4bit","choices":[],"usage":{"prompt_tokens":284,"completion_tokens":33,"total_tokens":317,"input_tokens":284,"output_tokens":33,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}"#,
        ])

        #expect(calls.map(\.name) == ["web_search"])
        #expect(calls.map(\.args) == [#"{"query": "latest Swift release 2026 date"}"#])
    }

    /// oMLX emits parallel calls one delta each, numbered by `index`
    /// (`index = len(streamed_tool_calls)` / `enumerate(tool_calls)`).
    /// The first call is captured; the second call delta (`call_1be04c61`,
    /// Paris) is built from that source, as the small model made one call.
    @Test
    func `oMLX parallel calls`() async throws {
        let calls = try await collectCalls(from: [
            #"{"id":"chatcmpl-b5eadcd3","object":"chat.completion.chunk","created":1795232940,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"role":"assistant"}}]}"#,
            #"{"id":"chatcmpl-b5eadcd3","object":"chat.completion.chunk","created":1795232943,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_0af93578","type":"function","function":{"name":"get_weather","arguments":"{\"city\": \"Tokyo\"}"}}]}}]}"#,
            #"{"id":"chatcmpl-b5eadcd3","object":"chat.completion.chunk","created":1795232943,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"call_1be04c61","type":"function","function":{"name":"get_weather","arguments":"{\"city\": \"Paris\"}"}}]}}]}"#,
            #"{"id":"chatcmpl-b5eadcd3","object":"chat.completion.chunk","created":1795232943,"model":"Qwen3.5-0.8B-4bit","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.map(\.id) == ["call_0af93578", "call_1be04c61"])
        #expect(calls.map(\.args) == [#"{"city": "Tokyo"}"#, #"{"city": "Paris"}"#])
    }

    /// mlx-lm `mlx_lm.server` (ml-explore/mlx-lm 2d4df8d, `ToolCallFormatter`):
    /// whole calls with a UUID id and a running `index`, every delta repeats
    /// `role`, and content deltas may sit between the calls.
    @Test
    func `mlx-lm parallel calls`() async throws {
        let calls = try await collectCalls(from: [
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion.chunk", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "\n\n"}}]}"#,
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion.chunk", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "get_weather", "arguments": "{\"city\": \"Tokyo\"}"}, "type": "function", "id": "1df7552f-172e-427f-a7ef-25d50551679d", "index": 0}]}}]}"#,
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion.chunk", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "content": "\n"}}]}"#,
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion.chunk", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [{"index": 0, "finish_reason": null, "delta": {"role": "assistant", "tool_calls": [{"function": {"name": "get_weather", "arguments": "{\"city\": \"Paris\"}"}, "type": "function", "id": "ef0f584e-800a-40ec-a6fe-8959a55afac6", "index": 1}]}}]}"#,
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion.chunk", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [{"index": 0, "finish_reason": "tool_calls", "delta": {"role": "assistant"}}]}"#,
            #"{"id": "chatcmpl-45f91445", "object": "chat.completion", "model": "Qwen3.5-0.8B-4bit", "created": 1795232947, "choices": [], "usage": {"prompt_tokens": 278, "completion_tokens": 107, "total_tokens": 385}}"#,
        ])

        #expect(calls.map(\.id) == ["1df7552f-172e-427f-a7ef-25d50551679d", "ef0f584e-800a-40ec-a6fe-8959a55afac6"])
        #expect(calls.map(\.name) == ["get_weather", "get_weather"])
        #expect(calls.map(\.args) == [#"{"city": "Tokyo"}"#, #"{"city": "Paris"}"#])
    }

    // MARK: - Built from server source

    /// vLLM (vllm/tool_parsers/hermes_tool_parser.py, streaming.py): the
    /// first delta of a call has `index`, `id`, `type` and `name`; later
    /// deltas have only `index` and an `arguments` fragment.
    @Test
    func `vLLM header then argument fragments`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"chatcmpl-tool-8a1f","type":"function","function":{"name":"get_weather"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\": "}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Tokyo\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"chatcmpl-tool-9b20","type":"function","function":{"name":"get_weather"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"arguments":"{\"city\": \"Paris\"}"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":""},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.map(\.id) == ["chatcmpl-tool-8a1f", "chatcmpl-tool-9b20"])
        #expect(calls.map(\.args) == [#"{"city": "Tokyo"}"#, #"{"city": "Paris"}"#])
    }

    /// llama.cpp server (tools/server/server-chat.cpp
    /// `server_chat_msg_diff_to_json_oaicompat`): `id`, `type` and `name`
    /// only when they change, `arguments` as text diffs.
    @Test
    func `llama.cpp diffs`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"id":"Xk2fQp9aLmN0","type":"function","function":{"name":"get_weather","arguments":"{\""}}]}}]}"#,
            #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"city\":"}}]}}]}"#,
            #"{"choices":[{"finish_reason":null,"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Tokyo\"}"}}]}}]}"#,
            #"{"choices":[{"finish_reason":"tool_calls","index":0,"delta":{}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// llama.cpp lets a partially parsed name grow; the delta then carries
    /// the same id and the whole, longer name (common/chat.cpp
    /// `common_chat_msg_diff::compute_diffs`).
    @Test
    func `llama.cpp name that grows keeps one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"Xk2fQp9aLmN0","type":"function","function":{"name":"get_wea"}}]}}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"Xk2fQp9aLmN0","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// Ollama (openai/openai.go `ToToolCalls`): whole calls, `call_` ids,
    /// per-call `index`, `"content":""` next to them.
    @Test
    func `Ollama whole calls`() async throws {
        let calls = try await collectCalls(from: [
            #"{"id":"chatcmpl-62","object":"chat.completion.chunk","created":1795232947,"model":"qwen3-coder","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","tool_calls":[{"id":"call_k3n2m1","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}},{"id":"call_p8q7r6","index":1,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]},"finish_reason":null}]}"#,
            #"{"id":"chatcmpl-62","object":"chat.completion.chunk","created":1795232947,"model":"qwen3-coder","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.map(\.id) == ["call_k3n2m1", "call_p8q7r6"])
        #expect(calls.map(\.args) == [#"{"city":"Tokyo"}"#, #"{"city":"Paris"}"#])
    }

    // MARK: - Repeated fields

    /// A server that repeats the same id and name on every fragment.
    @Test
    func `Same id and name on every fragment join one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"\"Tokyo\""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// A server without ids that repeats the name on every fragment.
    @Test
    func `Name on every fragment without ids joins one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":"\"Tokyo\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// A server that mints a new id for every fragment of one call. Only the
    /// first fragment names the tool, so the later ones continue it.
    @Test
    func `Fresh id on unnamed fragments joins one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"get_weather","arguments":"{\"city\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_2","type":"function","function":{"arguments":"\"Tokyo\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_1")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// The id on the first fragment, an empty id and empty name later.
    @Test
    func `Empty id and name on later fragments join one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","function":{"name":"","arguments":"{\"city\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","function":{"name":"","arguments":"\"Tokyo\"}"}}]}}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.id == "call_a")
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// A whole call, then empty deltas for the same call.
    @Test
    func `Whole call followed by empty deltas stays one call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
        ])

        #expect(calls.count == 1)
        #expect(calls.first?.name == "get_weather")
        #expect(calls.first?.args == #"{"city":"Tokyo"}"#)
    }

    /// Without ids, a repeated name after complete arguments is a second
    /// call of the same tool (Gemini-style).
    @Test
    func `Repeated name after complete arguments starts a new call`() async throws {
        let calls = try await collectCalls(from: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Tokyo\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Paris\"}"}}]}}]}"#,
        ])

        #expect(calls.map(\.args) == [#"{"city":"Tokyo"}"#, #"{"city":"Paris"}"#])
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
            model: "local-test",
            baseURL: "http://127.0.0.1:8000",
            path: "/v1/chat/completions",
            apiKey: "",
            dependencies: dependencies
        )

        let stream = try await client.streamingChat(body: ChatRequestBody(messages: [.user(content: .text("Hi"))]))
        var calls: [ToolRequest] = []
        for try await chunk in stream {
            if let call = chunk.toolValue { calls.append(call) }
        }
        #expect(client.collectedErrors == nil)
        return calls
    }
}
