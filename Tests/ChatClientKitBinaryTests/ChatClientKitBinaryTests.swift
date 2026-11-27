import ChatClientKit
import Foundation
import Metal
import ServerEvent
import Testing

/// Public-API tests that run identically against both the prebuilt
/// `ChatClientKit.xcframework` and source builds (no `@testable` imports,
/// no direct MLX/Tokenizers imports).
struct ChatClientKitBinaryTests {
    @Test
    func `RequestBuilder builds sanitized ChatRequestBody with tools and messages`() throws {
        let request = ChatRequest {
            ChatRequest.model("test-model")
            ChatRequest.temperature(0.25)
            ChatRequest.maxCompletionTokens(256)
            ChatRequest.messages {
                ChatRequest.Message.system(content: .text("Be concise."))
                ChatRequest.Message.user(content: .text("Hello"))
            }
            ChatRequest.tools([
                .function(
                    name: "get_weather",
                    description: "Look up weather",
                    parameters: [
                        "type": .string("object"),
                        "properties": .object(["city": .object(["type": .string("string")])]),
                    ],
                    strict: true
                ),
            ])
        }

        let body = try request.asChatRequestBody()
        #expect(body.model == "test-model")
        #expect(body.temperature == 0.25)
        #expect(body.maxCompletionTokens == 256)
        #expect(body.messages.count == 2)
        #expect(body.tools?.count == 1)

        let toolRequest = ToolRequest(
            id: "call_pub",
            name: "get_weather",
            args: #"{"city":"Tokyo"}"#,
            extraFields: ["vendor": .string("demo")]
        )
        #expect(toolRequest.id == "call_pub")
        #expect(toolRequest.extraFields?["vendor"] == .string("demo"))

        let call = ChatRequestBody.Message.ToolCall(
            id: toolRequest.id,
            function: .init(name: toolRequest.name, arguments: toolRequest.args),
            extraFields: toolRequest.extraFields
        )
        #expect(call.id == "call_pub")
        #expect(call.function.name == "get_weather")

        let merged = ChatRequest.mergeAssistantMessages([
            .assistant(content: .text("part 1")),
            .assistant(content: .text("part 2")),
        ])
        #expect(merged.count == 1)
    }

    @Test
    func `ServerEvent SSE parsing works through both ChatClientKit and ServerEvent shim`() throws {
        let payload = Data("id: evt-1\nevent: message\ndata: {\"ok\":true}\n".utf8)
        let parsed = try #require(ServerSentEvent.parse(from: payload))
        #expect(parsed.id == "evt-1")
        #expect(parsed.event == "message")
        #expect(parsed.data == #"{"ok":true}"#)

        let eventSource = EventSource(timeoutInterval: 900)
        #expect(eventSource.timeoutInterval == 900)
    }

    @Test
    func `RemoteCompletionsChatClient streams text, reasoning, and tool calls via mocked EventSource`() async throws {
        let events: [EventSource.EventType] = [
            .open,
            .event(ServerSentEvent(data: #"{"choices":[{"delta":{"reasoning_content":"think "}}]}"#)),
            .event(ServerSentEvent(data: #"{"choices":[{"delta":{"content":"hello "}}]}"#)),
            .event(ServerSentEvent(data: #"{"choices":[{"delta":{"content":"world"}}]}"#)),
            .event(ServerSentEvent(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"lookup","arguments":"{\"q\":\"swift\"}"}}]}}]}"#)),
            .event(ServerSentEvent(data: "[DONE]")),
            .closed,
        ]

        var dependencies = RemoteClientDependencies.live
        dependencies.eventSourceFactory = StubEventSourceFactory(recordedEvents: events)

        let client = RemoteCompletionsChatClient(
            model: "gpt-4o-mini",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: "test-key",
            dependencies: dependencies
        )

        let response = try await client.chat(body: ChatRequestBody(
            messages: [.user(content: .text("Hi"))]
        ))

        #expect(response.reasoning == "think ")
        #expect(response.text == "hello world")
        #expect(response.tools.count == 1)
        #expect(response.tools.first?.id == "call_1")
        #expect(response.tools.first?.name == "lookup")
        #expect(response.tools.first?.args == #"{"q":"swift"}"#)
    }

    @Test
    func `RemoteResponsesChatClient streams text, reasoning, and tool calls via mocked EventSource`() async throws {
        let events: [EventSource.EventType] = [
            .open,
            .event(ServerSentEvent(data: #"{"type":"response.reasoning_summary_text.delta","item_id":"rs_1","summary_index":0,"delta":"step 1"}"#)),
            .event(ServerSentEvent(data: #"{"type":"response.output_text.delta","item_id":"msg_1","output_index":0,"delta":"answer"}"#)),
            .event(ServerSentEvent(data: #"{"type":"response.output_item.added","output_index":1,"item":{"id":"fc_1","type":"function_call","call_id":"call_2","name":"search","arguments":""}}"#)),
            .event(ServerSentEvent(data: #"{"type":"response.function_call_arguments.delta","item_id":"fc_1","output_index":1,"delta":"{\"k\":1}"}"#)),
            .event(ServerSentEvent(data: #"{"type":"response.function_call_arguments.done","item_id":"fc_1","output_index":1,"arguments":"{\"k\":1}"}"#)),
            .event(ServerSentEvent(data: #"{"type":"response.completed"}"#)),
            .closed,
        ]

        var dependencies = RemoteClientDependencies.live
        dependencies.eventSourceFactory = StubEventSourceFactory(recordedEvents: events)

        let client = RemoteResponsesChatClient(
            model: "gpt-5",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: "test-key",
            dependencies: dependencies
        )

        let response = try await client.chat(body: ChatRequestBody(
            messages: [.user(content: .text("Hi"))]
        ))

        #expect(response.reasoning == "step 1")
        #expect(response.text == "answer")
        #expect(response.tools.count == 1)
        #expect(response.tools.first?.id == "call_2")
        #expect(response.tools.first?.name == "search")
        #expect(response.tools.first?.args == #"{"k":1}"#)
    }

    @Test
    func `AppleIntelligencePromptBuilder builds instructions and latest user prompt`() {
        let messages: [ChatRequestBody.Message] = [
            .system(content: .text("System note")),
            .user(content: .text("First question")),
            .assistant(content: .text("First answer")),
            .user(content: .text("Final question")),
        ]

        let instructions = AppleIntelligencePromptBuilder.makeInstructions(
            persona: "Helpful assistant",
            messages: messages,
            additionalDirectives: ["Be brief."]
        )
        #expect(instructions.contains("Helpful assistant"))
        #expect(instructions.contains("System note"))
        #expect(instructions.contains("Be brief."))
        #expect(AppleIntelligencePromptBuilder.makePrompt(from: messages) == "Final question")
    }

    @Test
    func `MLX public surface constructs client, resets coordinator, and clears memory cache`() async {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }

        let client = MLXChatClient(
            url: URL(fileURLWithPath: "/tmp/nonexistent-mlx-model"),
            preferredKind: .llm
        )
        let token = MLXChatClientQueue.shared.acquire()
        MLXChatClientQueue.shared.release(token: token)
        await MLXModelCoordinator.shared.reset()
        #expect(await client.errorCollector.getError() == nil)

        #if !targetEnvironment(simulator) && !arch(x86_64)
            if MTLCreateSystemDefaultDevice() != nil {
                MLXModelCoordinator.clearMemoryCache()
            }
        #endif
    }
}

private struct StubEventSourceFactory: EventSourceProducing {
    let recordedEvents: [EventSource.EventType]

    func makeDataTask(for _: URLRequest) -> EventStreamTask {
        StubEventStreamTask(recordedEvents: recordedEvents)
    }
}

private struct StubEventStreamTask: EventStreamTask {
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
