@testable import ChatClientKit
import Foundation
import FoundationModels
import Testing

// Convenience shims to align test expectations with current ChatClientKit types.
private typealias Function = ChatRequestBody.Message.ToolCall.Function
private typealias ToolCall = ChatCompletionChunk.Choice.Delta.ToolCall

private extension ChatRequestBody.Message.ToolCall.Function {
    var argumentsRaw: String? {
        arguments
    }

    var parsedArguments: [String: Any]? {
        guard let arguments, let data = arguments.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension ChatCompletionChunk.Choice.Delta.ToolCall.Function {
    var parsedArguments: [String: Any]? {
        guard let arguments, let data = arguments.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private extension ChatCompletionChunk.Choice.Delta.ToolCall {
    init(id: String, functionName: String, argumentsJSON: String) {
        self.init(
            index: nil,
            id: id,
            type: "function",
            function: .init(name: functionName, arguments: argumentsJSON)
        )
    }
}

struct AppleIntelligenceFunctionTests {
    @Test
    func `Function initializer parses arguments`() {
        let json = #"{"query":"weather","count":3}"#
        let function = Function(name: "tool", arguments: json)

        #expect(function.name == "tool")
        #expect(function.argumentsRaw == json)

        guard let arguments = function.parsedArguments else {
            Issue.record("Expected parsed arguments")
            return
        }
        #expect(arguments["query"] as? String == "weather")
        #expect(arguments["count"] as? Int == 3)
    }

    @Test
    func `Function initializer handles invalid JSON`() {
        let json = "{ invalid json"
        let function = Function(name: "tool", arguments: json)

        #expect(function.name == "tool")
        #expect(function.argumentsRaw == json)
        #expect(function.parsedArguments == nil)
    }

    @Test
    func `Tool call initializer produces function call`() {
        let call = ToolCall(id: "call-id", functionName: "tool", argumentsJSON: #"{"value":42}"#)

        #expect(call.id == "call-id")
        #expect(call.type == "function")
        #expect(call.function?.name == "tool")
        let args = call.function?.parsedArguments ?? [:]
        #expect(args["value"] as? Int == 42)
    }
}

struct AppleIntelligencePromptBuilderTests {
    @Test
    func `makeInstructions aggregates persona and guidance`() {
        let messages: [ChatRequestBody.Message] = [
            .system(content: .text("Follow system instructions.")),
            .developer(content: .text("Developer wants structured output.")),
            .user(content: .text("Hello")),
        ]
        let result = AppleIntelligencePromptBuilder.makeInstructions(
            persona: "You are a helpful assistant.",
            messages: messages,
            additionalDirectives: ["Please respond in Markdown."]
        )

        #expect(result.contains("You are a helpful assistant."))
        #expect(result.contains("Follow system instructions."))
        #expect(result.contains("Developer wants structured output."))
        #expect(result.contains("Please respond in Markdown."))
    }

    @Test
    func `makeInstructions separates blocks with a blank line`() {
        let result = AppleIntelligencePromptBuilder.makeInstructions(
            persona: "Persona.",
            messages: [.system(content: .text("System."))],
            additionalDirectives: ["Directive."]
        )

        #expect(result == "Persona.\n\nSystem.\n\nDirective.")
    }

    @Test
    func `makePrompt sends the only user message verbatim`() {
        let messages: [ChatRequestBody.Message] = [
            .system(content: .text("You are a helpful assistant.")),
            .user(content: .text("今天星期几")),
        ]

        #expect(AppleIntelligencePromptBuilder.makePrompt(from: messages) == "今天星期几")
        #expect(AppleIntelligencePromptBuilder.makeHistory(from: messages).isEmpty)
    }

    @Test
    func `makePrompt sends the latest user message without a role label`() {
        let messages: [ChatRequestBody.Message] = [
            .user(content: .text("First question")),
            .assistant(
                content: .text("First answer"),
                toolCalls: [.init(
                    id: "call_1",
                    function: .init(name: "lookup", arguments: #"{"query":"weather"}"#)
                )]
            ),
            .tool(content: .text("tool output"), toolCallID: "call_1"),
            .user(content: .text("Latest question"), name: "Alex"),
        ]

        let prompt = AppleIntelligencePromptBuilder.makePrompt(from: messages)
        let history = AppleIntelligencePromptBuilder.makeHistory(from: messages)

        #expect(prompt == "Latest question")
        #expect(history == [
            .prompt("First question"),
            .response("First answer"),
            .toolCalls([.init(id: "call_1", name: "lookup", arguments: #"{"query":"weather"}"#)]),
            .toolOutput(id: "call_1", toolName: "lookup", text: "tool output"),
        ])
    }

    @Test
    func `Tool round keeps the user question as the prompt and the output in history`() {
        let messages: [ChatRequestBody.Message] = [
            .system(content: .text("You are a helpful assistant.")),
            .user(content: .text("今天星期几")),
            .assistant(toolCalls: [.init(
                id: "call_date",
                function: .init(name: "get_date", arguments: "{}")
            )]),
            .tool(content: .text("2026-11-11, Wednesday"), toolCallID: "call_date"),
        ]

        #expect(AppleIntelligencePromptBuilder.makePrompt(from: messages) == "今天星期几")
        #expect(AppleIntelligencePromptBuilder.makeHistory(from: messages) == [
            .toolCalls([.init(id: "call_date", name: "get_date", arguments: "{}")]),
            .toolOutput(id: "call_date", toolName: "get_date", text: "2026-11-11, Wednesday"),
        ])
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Session context carries history in the transcript, not the prompt`() throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(messages: [
            .system(content: .text("Be brief.")),
            .user(content: .text("First question")),
            .assistant(content: .text("First answer")),
            .user(content: .text("今天星期几")),
        ])

        let context = try client.makeSessionContext(body: body, persona: "")
        let entries = Array(context.session.transcript)

        #expect(context.prompt == "今天星期几")
        #expect(entries.count == 3)
        guard entries.count == 3 else { return }
        guard case let .instructions(instructions) = entries[0] else {
            Issue.record("Expected instructions first")
            return
        }
        #expect(text(of: instructions.segments) == "Be brief.")
        guard case let .prompt(prompt) = entries[1] else {
            Issue.record("Expected the earlier user message as a prompt entry")
            return
        }
        #expect(text(of: prompt.segments) == "First question")
        guard case let .response(response) = entries[2] else {
            Issue.record("Expected the earlier answer as a response entry")
            return
        }
        #expect(text(of: response.segments) == "First answer")
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Session context exposes the tool output on a tool round`() throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [
                .user(content: .text("今天星期几")),
                .assistant(toolCalls: [.init(
                    id: "call_date",
                    function: .init(name: "get_date", arguments: #"{"format":"weekday"}"#)
                )]),
                .tool(content: .text("Wednesday"), toolCallID: "call_date"),
            ],
            tools: [.function(name: "get_date", description: "Current date", parameters: nil, strict: nil)]
        )

        let context = try client.makeSessionContext(body: body, persona: "Persona.")
        let entries = Array(context.session.transcript)

        #expect(context.prompt == "今天星期几")
        #expect(entries.count == 3)
        guard entries.count == 3 else { return }
        guard case let .instructions(instructions) = entries[0] else {
            Issue.record("Expected instructions first")
            return
        }
        #expect(instructions.toolDefinitions.map(\.name) == ["get_date"])
        guard case let .toolCalls(calls) = entries[1] else {
            Issue.record("Expected the tool call entry")
            return
        }
        #expect(calls.map(\.toolName) == ["get_date"])
        #expect(calls.map(\.id) == ["call_date"])
        guard case let .toolOutput(output) = entries[2] else {
            Issue.record("Expected the tool output entry")
            return
        }
        #expect(output.id == "call_date")
        #expect(output.toolName == "get_date")
        #expect(text(of: output.segments) == "Wednesday")
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Session context without history keeps the plain instructions session`() throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(messages: [
            .system(content: .text("Be brief.")),
            .user(content: .text("今天星期几")),
        ])

        let context = try client.makeSessionContext(body: body, persona: "")
        let entries = Array(context.session.transcript)

        #expect(context.prompt == "今天星期几")
        #expect(entries.count == 1)
        guard case let .instructions(instructions) = entries.first else {
            Issue.record("Expected only the instructions entry")
            return
        }
        #expect(text(of: instructions.segments) == "Be brief.")
    }

    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    private func text(of segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            if case let .text(text) = segment { text.content } else { nil }
        }.joined()
    }
}

struct AppleIntelligenceStreamStateTests {
    @Test
    func `Text deltas remain ordered before a captured tool call`() {
        var state = AppleIntelligenceStreamState()
        let request = ToolRequest(id: "call-id", name: "lookup", args: #"{"city":"Paris"}"#)

        let chunks = [
            state.textChunk(for: "Checking"),
            state.textChunk(for: "Checking now."),
            state.toolChunk(for: request),
        ].compactMap { $0 }

        #expect(chunks == [
            .text("Checking"),
            .text(" now."),
            .tool(request),
        ])
    }

    @Test
    func `Repeated cumulative text does not duplicate output`() {
        var state = AppleIntelligenceStreamState()

        #expect(state.textChunk(for: "Ready") == .text("Ready"))
        #expect(state.textChunk(for: "Ready") == nil)
    }
}

struct AppleIntelligenceToolProxyTests {
    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Tool proxy preserves its schema and captures native arguments`() async throws {
        let proxy = try AppleIntelligenceToolProxy(
            name: "lookupWeather",
            description: "Fetch latest weather info.",
            parameters: [
                "type": "object",
                "properties": [
                    "city": [
                        "type": "string",
                        "description": "City name",
                    ],
                ],
                "required": ["city"],
                "additionalProperties": false,
            ]
        )
        let encodedSchema = String(
            decoding: try JSONEncoder().encode(proxy.parameters),
            as: UTF8.self
        )
        #expect(encodedSchema.contains(#""city""#))
        #expect(encodedSchema.contains(#""required""#))

        do {
            _ = try await proxy.call(
                arguments: GeneratedContent(properties: ["city": "Paris"])
            )
            Issue.record("Expected invocation capture error")
        } catch let AppleIntelligenceToolError.invocationCaptured(request) {
            #expect(request.name == "lookupWeather")
            let data = try #require(request.args.data(using: .utf8))
            let arguments = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            #expect(arguments == ["city": "Paris"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Specific tool choice exposes only the selected function`() throws {
        let tools: [ChatRequestBody.Tool] = [
            .function(name: "weather", description: nil, parameters: nil, strict: nil),
            .function(name: "calendar", description: nil, parameters: nil, strict: nil),
        ]
        let body = ChatRequestBody(tools: tools, toolChoice: .function(name: "calendar"))

        let selected = try body.selectedTools()

        #expect(selected.count == 1)
        guard case let .function(name, _, _, _) = selected[0] else {
            Issue.record("Expected a function tool")
            return
        }
        #expect(name == "calendar")
        #expect(body.toolChoiceDirective == "Call the calendar tool. Do not answer the user directly.")
    }

    @Test
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Required tool choice rejects an empty tool list`() {
        let body = ChatRequestBody(toolChoice: .required)

        #expect(throws: Error.self) {
            _ = try body.selectedTools()
        }
        #expect(body.toolChoiceDirective == "Call one of the available tools before answering the user.")
    }

    @Test
    @available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *)
    func `Session context preserves maximum response tokens`() throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [.user(content: .text("Check Paris weather"))],
            maxCompletionTokens: 48
        )

        let context = try client.makeSessionContext(body: body, persona: "")

        #expect(context.options.maximumResponseTokens == 48)
    }
}

struct AppleIntelligenceIntegrationTests {
    @Test(.enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Basic chat completion`() async throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant. Keep responses very brief.")),
                .user(content: .text("Say 'Hello World' and nothing else.")),
            ],
            maxCompletionTokens: 20,
            temperature: 0.5
        )

        let response: ChatResponse = try await client.chat(body: body)

        let text = try #require(response.text.isEmpty ? nil : response.text)
        #expect(text.isEmpty == false)

        print("✅ Basic completion test passed. Response: \(text)")
    }

    @Test(.enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Streaming chat completion`() async throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant.")),
                .user(content: .text("Count from 1 to 5 with spaces between numbers.")),
            ],
            maxCompletionTokens: 50,
            temperature: 0.3
        )

        let stream = try await client.streamingChat(body: body)
        var accumulatedContent = ""
        var chunkCount = 0

        for try await chunk in stream {
            if let content = chunk.textValue {
                accumulatedContent += content
                chunkCount += 1
            } else if case .tool = chunk {
                Issue.record("Unexpected tool call in basic streaming test")
            }
        }

        #expect(chunkCount > 0)
        #expect(accumulatedContent.isEmpty == false)

        print("✅ Streaming test passed. Chunks: \(chunkCount), Content: \(accumulatedContent)")
    }

    @Test(.enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func `Tool call generation`() async throws {
        let client = AppleIntelligenceChatClient()
        let tools: [ChatRequestBody.Tool] = [
            .function(
                name: "get_weather",
                description: "Get the current weather for a location",
                parameters: [
                    "type": .string("object"),
                    "properties": .object([
                        "location": .object([
                            "type": .string("string"),
                            "description": .string("City name"),
                        ]),
                    ]),
                    "required": .array([.string("location")]),
                ],
                strict: nil
            ),
        ]

        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant with access to tools.")),
                .user(content: .text("What's the weather in Tokyo?")),
            ],
            maxCompletionTokens: 100,
            temperature: 0.5,
            tools: tools,
            toolChoice: .function(name: "get_weather")
        )

        let stream = try await client.streamingChat(body: body)
        var chunks: [ChatResponseChunk] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        let toolIndex = try #require(chunks.firstIndex(where: { $0.toolValue != nil }))
        let tool = try #require(chunks[toolIndex].toolValue)
        #expect(tool.name == "get_weather")
        #expect(chunks[(toolIndex + 1)...].isEmpty)
    }
}
