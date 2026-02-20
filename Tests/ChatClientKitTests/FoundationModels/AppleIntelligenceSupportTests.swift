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
            function: .init(name: functionName, arguments: argumentsJSON),
        )
    }
}

@Suite("Apple Intelligence Function Tests")
struct AppleIntelligenceFunctionTests {
    @Test("Function initializer parses arguments")
    func functionInitializerParsesArguments() {
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

    @Test("Function initializer handles invalid JSON")
    func functionInitializerHandlesInvalidJSON() {
        let json = "{ invalid json"
        let function = Function(name: "tool", arguments: json)

        #expect(function.name == "tool")
        #expect(function.argumentsRaw == json)
        #expect(function.parsedArguments == nil)
    }

    @Test("Tool call initializer produces function call")
    func toolCallInitializerProducesFunctionCall() {
        let call = ToolCall(id: "call-id", functionName: "tool", argumentsJSON: #"{"value":42}"#)

        #expect(call.id == "call-id")
        #expect(call.type == "function")
        #expect(call.function?.name == "tool")
        let args = call.function?.parsedArguments ?? [:]
        #expect(args["value"] as? Int == 42)
    }
}

@Suite("Apple Intelligence Prompt Builder Tests")
struct AppleIntelligencePromptBuilderTests {
    @Test("makeInstructions aggregates persona and guidance")
    func makeInstructionsAggregatesPersonaAndGuidance() {
        let messages: [ChatRequestBody.Message] = [
            .system(content: .text("Follow system instructions.")),
            .developer(content: .text("Developer wants structured output.")),
            .user(content: .text("Hello")),
        ]
        let result = AppleIntelligencePromptBuilder.makeInstructions(
            persona: "You are a helpful assistant.",
            messages: messages,
            additionalDirectives: ["Please respond in Markdown."],
        )

        #expect(result.contains("You are a helpful assistant."))
        #expect(result.contains("Follow system instructions."))
        #expect(result.contains("Developer wants structured output."))
        #expect(result.contains("Please respond in Markdown."))
    }

    @Test("makePrompt prioritizes latest user message")
    func makePromptPrioritizesLatestUserMessage() {
        let messages: [ChatRequestBody.Message] = [
            .user(content: .text("First question")),
            .assistant(content: .text("First answer")),
            .tool(content: .text("tool output"), toolCallID: "call_1"),
            .user(content: .text("Latest question"), name: "Alex"),
        ]

        let prompt = AppleIntelligencePromptBuilder.makePrompt(from: messages)

        #expect(prompt.contains("Conversation so far"))
        #expect(prompt.contains("User: First question"))
        #expect(prompt.contains("Assistant: First answer"))
        #expect(prompt.contains("Tool(call_1): tool output"))
        #expect(prompt.contains("User (Alex): Latest question"))
    }
}

@Suite("Apple Intelligence Tool Proxy Tests")
struct AppleIntelligenceToolProxyTests {
    @Test("Tool proxy captures invocation")
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func toolProxyCapturesInvocation() async throws {
        let proxy = AppleIntelligenceToolProxy(
            name: "lookupWeather",
            description: "Fetch latest weather info.",
            schemaDescription: nil,
        )

        do {
            _ = try await proxy.call(arguments: .init(payload: #"{"city":"Paris"}"#))
            Issue.record("Expected invocation capture error")
        } catch let AppleIntelligenceToolError.invocationCaptured(request) {
            #expect(request.name == "lookupWeather")
            #expect(request.args == #"{"city":"Paris"}"#)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("Apple Intelligence Integration Tests")
struct AppleIntelligenceIntegrationTests {
    @Test("Basic chat completion", .enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func basicChatCompletion() async throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant. Keep responses very brief.")),
                .user(content: .text("Say 'Hello World' and nothing else.")),
            ],
            maxCompletionTokens: 20,
            temperature: 0.5,
        )

        let response: ChatResponse = try await client.chat(body: body)

        let text = try #require(response.text.isEmpty ? nil : response.text)
        #expect(text.isEmpty == false)

        print("✅ Basic completion test passed. Response: \(text)")
    }

    @Test("Streaming chat completion", .enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func streamingChatCompletion() async throws {
        let client = AppleIntelligenceChatClient()
        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are a helpful assistant.")),
                .user(content: .text("Count from 1 to 5 with spaces between numbers.")),
            ],
            maxCompletionTokens: 50,
            temperature: 0.3,
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

    @Test("Tool call generation", .enabled(if: TestHelpers.isAppleIntelligenceAvailable))
    @available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
    func toolCallGeneration() async throws {
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
                strict: nil,
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
        )

        let response: ChatResponse = try await client.chat(body: body)

        if let tool = response.tools.first {
            print("✅ Tool call test passed. Generated tool call \(tool.name) args: \(tool.args)")
        } else if !response.text.isEmpty {
            print("⚠️ Model did not generate tool calls (may respond directly instead)")
            print("  Response content: \(response.text)")
        } else {
            Issue.record("No tool call or text content returned.")
        }
    }
}
