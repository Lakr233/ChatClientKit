//
//  LocalServerToolCallTests.swift
//  ChatClientKitTests
//

@testable import ChatClientKit
import Foundation
import Testing

/// Runs the real streaming client against an OpenAI-compatible server on
/// this machine (oMLX, `mlx_lm.server`, llama.cpp, LM Studio, …) and checks
/// that a streamed tool call comes out whole. Enabled only when
/// `CHATCLIENTKIT_LOCAL_SERVER_URL` (e.g. `http://127.0.0.1:8000`) and
/// `CHATCLIENTKIT_LOCAL_SERVER_MODEL` are set; `xcodebuild test` passes them
/// through as `TEST_RUNNER_CHATCLIENTKIT_LOCAL_SERVER_URL` and so on.
struct LocalServerToolCallTests {
    static let baseURL = ProcessInfo.processInfo.environment["CHATCLIENTKIT_LOCAL_SERVER_URL"] ?? ""
    static let model = ProcessInfo.processInfo.environment["CHATCLIENTKIT_LOCAL_SERVER_MODEL"] ?? ""
    static let isConfigured = !baseURL.isEmpty && !model.isEmpty

    static let weatherTool = ChatRequestBody.Tool.function(
        name: "get_weather",
        description: "Get the current weather for a city",
        parameters: [
            "type": "object",
            "properties": [
                "city": ["type": "string", "description": "City name"],
            ],
            "required": ["city"],
        ],
        strict: nil
    )

    static let searchTool = ChatRequestBody.Tool.function(
        name: "web_search",
        description: "Search the web",
        parameters: [
            "type": "object",
            "properties": ["query": ["type": "string"]],
            "required": ["query"],
        ],
        strict: nil
    )

    @Test(.enabled(if: isConfigured))
    func `Streamed tool call from a local server comes out whole`() async throws {
        // A small model sometimes answers in text instead; ask again.
        let calls = try await firstCalls(
            prompt: "What is the weather in Tokyo right now? Call get_weather.",
            tools: [Self.weatherTool, Self.searchTool]
        )

        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.name == "get_weather")
        let arguments = try #require(Self.jsonObject(call.args))
        #expect((arguments["city"] as? String)?.isEmpty == false)
    }

    @Test(.enabled(if: isConfigured))
    func `Every streamed call from a local server parses`() async throws {
        let calls = try await firstCalls(
            prompt: "Get the weather in Tokyo and the weather in Paris. Call get_weather once per city.",
            tools: [Self.weatherTool]
        )

        #expect(!calls.isEmpty)
        for call in calls {
            #expect(call.name == "get_weather")
            #expect(Self.jsonObject(call.args) != nil, "arguments do not parse: \(call.args)")
        }
        #expect(Set(calls.map(\.id)).count == calls.count)
    }

    private func firstCalls(prompt: String, tools: [ChatRequestBody.Tool]) async throws -> [ToolRequest] {
        for _ in 1 ... 4 {
            let calls = try await streamCalls(prompt: prompt, tools: tools)
            if !calls.isEmpty { return calls }
        }
        return []
    }

    private func streamCalls(prompt: String, tools: [ChatRequestBody.Tool]) async throws -> [ToolRequest] {
        let client = RemoteCompletionsChatClient(
            model: Self.model,
            baseURL: Self.baseURL,
            path: "/v1/chat/completions",
            apiKey: "sk-local"
        )
        let stream = try await client.streamingChat(body: ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant. Use the provided tools when they help.")),
                .user(content: .text(prompt)),
            ],
            tools: tools
        ))
        var calls: [ToolRequest] = []
        for try await chunk in stream {
            if let call = chunk.toolValue {
                print("[LocalServerToolCallTests] tool call id=\(call.id) name=\(call.name) args=\(call.args)")
                calls.append(call)
            }
        }
        let errors = client.collectedErrors ?? ""
        #expect(errors.isEmpty, "collected errors: \(errors)")
        print("[LocalServerToolCallTests] \(calls.count) call(s)")
        return calls
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
