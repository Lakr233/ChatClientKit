//
//  ScriptingStreamProcessorTests.swift
//  ChatClientKitTests
//
//  Focused unit tests covering the four scripting review findings:
//  1. Recoverable post_process failures (1-2 consecutive) must not produce
//     a terminal error in errorCollector.
//  2. Three consecutive post_process failures produce a terminal error.
//  3. Completions scripting mode: provider error JSON reaches errorCollector.
//  4. Responses scripting: chatSession reflects the resolved model/stream.
//

@testable import ChatClientKit
import Foundation
import ServerEvent
import Testing

struct ScriptingStreamProcessorTests {
    // MARK: - Helpers

    private func makePostProcessHandle(script: String) -> ChatScriptingHandle {
        ChatScriptingHandle(
            conversationId: UUID().uuidString,
            config: ChatClientKitScriptConfig(
                preProcess: nil,
                postProcess: .init(inherit: false, script: script)
            ),
            manifest: ManifestSnapshot(payload: .object([:])),
            readContext: { "{}" },
            writeContext: { _ in }
        )
    }

    private func makeCompletionsClient(
        rawLines: [String]
    ) -> (client: RemoteCompletionsChatClient, factory: ScriptingMockEventFactory) {
        let factory = ScriptingMockEventFactory(rawLines: rawLines)
        let dependencies = RemoteClientDependencies(
            session: ScriptingMockURLSession(),
            eventSourceFactory: factory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteChatErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer()
        )
        let client = RemoteCompletionsChatClient(
            model: "test-model",
            baseURL: "https://example.com",
            path: "/v1/chat/completions",
            apiKey: "sk-test",
            dependencies: dependencies
        )
        return (client, factory)
    }

    private func makeResponsesClient(
        rawLines: [String]
    ) -> (client: RemoteResponsesChatClient, factory: ScriptingMockEventFactory) {
        let factory = ScriptingMockEventFactory(rawLines: rawLines)
        let dependencies = RemoteClientDependencies(
            session: ScriptingMockURLSession(),
            eventSourceFactory: factory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer()
        )
        let client = RemoteResponsesChatClient(
            model: "test-model",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: "sk-test",
            dependencies: dependencies
        )
        return (client, factory)
    }

    // MARK: - Test 1: Recoverable post_process failures - no terminal error

    @Test
    func `completions post_process fails first two chunks then recovers - no error collected`() async throws {
        // Script fails for first 2 invocations, succeeds from the 3rd onward.
        // Uses `context` which persists across invoke calls in the same JSContext.
        let script = """
        if (!context.count) context.count = 0;
        context.count++;
        if (context.count <= 2) { throw new Error("transient failure " + context.count); }
        __result = { content: "ok", reasoning: null, tool_calls: null };
        """
        let handle = makePostProcessHandle(script: script)

        let chunk = #"{"choices":[{"delta":{"content":"token"}}]}"#
        let (client, _) = makeCompletionsClient(rawLines: [chunk, chunk, chunk])

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )
        for try await _ in stream {}

        #expect(client.collectedErrors == nil,
                "Recoverable failures must not populate errorCollector")
    }

    @Test
    func `responses post_process fails first two chunks then recovers - no error collected`() async throws {
        let script = """
        if (!context.count) context.count = 0;
        context.count++;
        if (context.count <= 2) { throw new Error("transient failure " + context.count); }
        __result = { content: "ok", reasoning: null, tool_calls: null };
        """
        let handle = makePostProcessHandle(script: script)

        let chunk = #"{"type":"response.output_text.delta","item_id":"m1","delta":"Hi"}"#
        let (client, _) = makeResponsesClient(rawLines: [chunk, chunk, chunk])

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )
        for try await _ in stream {}

        #expect(client.collectedErrors == nil,
                "Recoverable failures must not populate errorCollector")
    }

    // MARK: - Test 2: Three consecutive failures -> terminal error

    @Test
    func `completions post_process three consecutive failures produce terminal error`() async throws {
        let script = """
        throw new Error("always fails");
        """
        let handle = makePostProcessHandle(script: script)

        let chunk = #"{"choices":[{"delta":{"content":"token"}}]}"#
        let (client, _) = makeCompletionsClient(rawLines: [chunk, chunk, chunk, chunk])

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )
        for try await _ in stream {}

        let errors = client.collectedErrors
        #expect(errors != nil, "Terminal error must be collected after 3 consecutive failures")
        // ScriptingStreamError.consecutivePostProcessFailures description contains the count
        let desc = errors ?? ""
        #expect(
            desc.contains("3") || desc.contains("consecutive") || desc.contains("post_process"),
            "Error description should identify the terminal post_process failure; got: \(desc)"
        )
    }

    @Test
    func `responses post_process three consecutive failures produce terminal error`() async throws {
        let script = """
        throw new Error("always fails");
        """
        let handle = makePostProcessHandle(script: script)

        let chunk = #"{"type":"response.output_text.delta","item_id":"m1","delta":"Hi"}"#
        let (client, _) = makeResponsesClient(rawLines: [chunk, chunk, chunk, chunk])

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )
        for try await _ in stream {}

        let errors = client.collectedErrors
        #expect(errors != nil, "Terminal error must be collected after 3 consecutive failures")
        let desc = errors ?? ""
        #expect(
            desc.contains("3") || desc.contains("consecutive") || desc.contains("post_process"),
            "Error description should identify the terminal post_process failure; got: \(desc)"
        )
    }

    // MARK: - Test 3: Completions scripting - provider error JSON reaches errorCollector

    @Test
    func `completions scripting mode surfaces provider error JSON into errorCollector`() async throws {
        // Script always succeeds; the provider error in the SSE data must still
        // reach errorCollector via errorExtractor.extractError inside Path A.
        let script = """
        __result = { content: null, reasoning: null, tool_calls: null };
        """
        let handle = makePostProcessHandle(script: script)

        // Standard OpenAI-style error payload
        let providerError = #"{"error":{"message":"Rate limit exceeded","type":"rate_limit_error","code":429}}"#
        let (client, _) = makeCompletionsClient(rawLines: [providerError])

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )
        for try await _ in stream {}

        let errors = client.collectedErrors
        #expect(errors != nil,
                "Provider error JSON must reach errorCollector even when scripting is active")
        #expect(errors?.contains("Rate limit") == true,
                "errorCollector should include the provider error message; got: \(errors ?? "nil")")
    }

    // MARK: - Test 4: Responses scripting chatSession reflects resolved model/stream

    @Test
    func `responses scripting chatSession contains resolved model and stream`() async throws {
        // Script reads chatSession.model and chatSession.stream and returns them
        // as content so we can verify the values from outside.
        let script = """
        var m = (chatSession && chatSession.model) ? chatSession.model : "MISSING_MODEL";
        var s = (chatSession && chatSession.stream !== undefined) ? String(chatSession.stream) : "MISSING_STREAM";
        __result = { content: m + "|" + s, reasoning: null, tool_calls: null };
        """
        let handle = ChatScriptingHandle(
            conversationId: UUID().uuidString,
            config: ChatClientKitScriptConfig(
                preProcess: nil,
                postProcess: .init(inherit: false, script: script)
            ),
            manifest: ManifestSnapshot(payload: .object([:])),
            readContext: { "{}" },
            writeContext: { _ in }
        )

        // Send one Responses-format chunk so the script fires once.
        let chunk = #"{"type":"response.output_text.delta","item_id":"m1","delta":"Hi"}"#
        let factory = ScriptingMockEventFactory(rawLines: [chunk])
        let dependencies = RemoteClientDependencies(
            session: ScriptingMockURLSession(),
            eventSourceFactory: factory,
            responseDecoderFactory: { JSONDecoderWrapper() },
            chunkDecoderFactory: { JSONDecoderWrapper() },
            errorExtractor: RemoteResponsesErrorExtractor(),
            reasoningParser: CompletionReasoningDecoder(),
            requestSanitizer: RequestSanitizer()
        )
        // model is set to "resolved-model" on the client; the body passed to
        // streamingChat has model=nil so we verify the resolved value propagates.
        let client = RemoteResponsesChatClient(
            model: "resolved-model",
            baseURL: "https://example.com",
            path: "/v1/responses",
            apiKey: "sk-test",
            dependencies: dependencies
        )

        let stream = try await client.streamingChat(
            body: ChatRequestBody(messages: [.user(content: .text("hi"))]),
            scripting: handle
        )

        var texts: [String] = []
        for try await chunk in stream {
            if let t = chunk.textValue { texts.append(t) }
        }
        let received = texts.joined()

        #expect(received.contains("resolved-model"),
                "chatSession.model must be the resolved model name; got: \(received)")
        #expect(received.contains("true"),
                "chatSession.stream must be true (resolved stream=true); got: \(received)")
    }
}

// MARK: - Test doubles (scoped to this file)

private final class ScriptingMockURLSession: URLSessioning, @unchecked Sendable {
    func data(for _: URLRequest) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

private final class ScriptingMockEventFactory: EventSourceProducing, @unchecked Sendable {
    private let recordedEvents: [EventSource.EventType]

    init(rawLines: [String]) {
        var evs: [EventSource.EventType] = [.open]
        for line in rawLines {
            evs.append(.event(ScriptingTestEvent(data: line)))
        }
        evs.append(.closed)
        recordedEvents = evs
    }

    func makeDataTask(for _: URLRequest) -> EventStreamTask {
        ScriptingMockEventStreamTask(recordedEvents: recordedEvents)
    }
}

private struct ScriptingMockEventStreamTask: EventStreamTask {
    let recordedEvents: [EventSource.EventType]

    func events() -> AsyncStream<EventSource.EventType> {
        AsyncStream { cont in
            for e in recordedEvents { cont.yield(e) }
            cont.finish()
        }
    }
}

private struct ScriptingTestEvent: EVEvent {
    var id: String?
    var event: String?
    var data: String?
    var other: [String: String]?
    var time: String?
}
