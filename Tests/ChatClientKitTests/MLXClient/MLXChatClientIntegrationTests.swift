//
//  MLXChatClientIntegrationTests.swift
//  ChatClientKitTests
//
//  Created by GPT-5 Codex on 2025/11/10.
//

@testable import ChatClientKit
import Foundation
@preconcurrency import MLX
import Testing

/// Runs real inference against the `mlx_testing_model` fixture
/// (`~/.testing/mlx_testing_model` or `<repo>/.test/mlx_testing_model`).
/// The fixture must be a chat model that can call tools, such as
/// `mlx-community/Qwen3.5-0.8B-4bit`.
@Suite(.serialized)
struct MLXChatClientIntegrationTests {
    @Test(.enabled(if: TestHelpers.isMLXModelAvailable))
    func `Local MLX chat completion returns content`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }

        let modelURL = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
        let client = MLXChatClient(url: modelURL)

        let response = try await client.chat(
            ChatRequestBody(
                messages: [
                    .system(content: .text("Respond succinctly with HELLO.")),
                    .user(content: .text("Say HELLO")),
                ],
                maxCompletionTokens: 32,
                temperature: 0.0
            )
        )

        let content = response
            .text
            .trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!content.isEmpty)
    }

    @Test(.enabled(if: TestHelpers.isMLXModelAvailable))
    func `Local MLX stream ends when its consumer is cancelled`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }

        let modelURL = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
        let client = MLXChatClient(url: modelURL)
        let chunksBeforeCancel = 8
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()

        let consumer = Task {
            defer { startedContinuation.finish() }
            let stream = try await client.streamingChat(body: ChatRequestBody(
                messages: [.user(content: .text("Count from 1 to 400, one number per line."))],
                maxCompletionTokens: 2048,
                temperature: 0.0
            ))
            var received = 0
            for try await chunk in stream {
                guard chunk.textValue != nil || chunk.reasoningValue != nil else { continue }
                received += 1
                if received == chunksBeforeCancel {
                    startedContinuation.yield()
                }
            }
            return received
        }

        for await _ in started {
            break
        }
        let cancelledAt = Date()
        consumer.cancel()
        let received = try await consumer.value
        let stopDelay = Date().timeIntervalSince(cancelledAt)

        #expect(received >= chunksBeforeCancel)
        #expect(received < 100)
        #expect(stopDelay < 5)

        // The cancelled stream must hand the MLX queue back, or this request
        // waits forever.
        let followUp = try await client.chat(body: ChatRequestBody(
            messages: [.user(content: .text("Say HELLO"))],
            maxCompletionTokens: 32,
            temperature: 0.0
        ))
        #expect(!followUp.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test(.enabled(if: TestHelpers.isMLXModelAvailable))
    func `Local MLX tool call round trip parses the call and answers from its result`() async throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }

        let modelURL = TestHelpers.fixtureURLOrSkip(named: "mlx_testing_model")
        let client = MLXChatClient(url: modelURL)
        let tool = ChatRequestBody.Tool.function(
            name: "get_weather",
            description: "Get the current weather for a city.",
            parameters: [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "The city name, for example Paris.",
                    ],
                ],
                "required": ["city"],
            ],
            strict: nil
        )
        let question = ChatRequestBody.Message.user(
            content: .text("What is the weather in Paris right now? Use the get_weather tool.")
        )

        let call = try await client.chat(body: ChatRequestBody(
            messages: [question],
            maxCompletionTokens: 512,
            temperature: 0.0,
            tools: [tool]
        ))

        let request = try #require(call.tools.first, "Expected a tool call, got text: \(call.text)")
        #expect(call.tools.count == 1)
        #expect(request.name == "get_weather")
        let decoded = try JSONSerialization.jsonObject(with: Data(request.args.utf8))
        let arguments = try #require(decoded as? [String: Any])
        #expect((arguments["city"] as? String)?.localizedCaseInsensitiveContains("Paris") == true)
        expectNoToolProtocolText(in: call.text)

        let answer = try await client.chat(body: ChatRequestBody(
            messages: [
                question,
                .assistant(toolCalls: [.init(
                    id: request.id,
                    function: .init(name: request.name, arguments: request.args)
                )]),
                .tool(
                    content: .text(#"{"city":"Paris","condition":"sunny","temperature_celsius":21}"#),
                    toolCallID: request.id
                ),
            ],
            maxCompletionTokens: 512,
            temperature: 0.0,
            tools: [tool]
        ))

        let text = answer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(answer.tools.isEmpty)
        #expect(!text.isEmpty)
        #expect(
            text.localizedCaseInsensitiveContains("sunny") || text.contains("21"),
            "Expected the answer to use the tool result, got: \(text)"
        )
        expectNoToolProtocolText(in: answer.text)
    }

    private func expectNoToolProtocolText(in text: String) {
        for marker in ["<tool_call>", "</tool_call>", "<function=", "<parameter="] {
            #expect(!text.contains(marker), "Tool-call markup leaked into the text: \(text)")
        }
    }
}
