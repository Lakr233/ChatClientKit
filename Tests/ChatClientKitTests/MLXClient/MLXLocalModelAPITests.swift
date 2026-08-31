@testable import ChatClientKit
import Foundation
import MLXLMCommon
import Testing

struct MLXLocalModelAPITests {
    @Test
    func `Specific tool choice filters schemas and augments system instructions`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(url: URL(fileURLWithPath: "/tmp/model"))
        let body = ChatRequestBody(
            messages: [
                .developer(content: .text("Follow application policy.")),
                .user(content: .text("Check my calendar.")),
            ],
            tools: [
                .function(name: "weather", description: nil, parameters: nil, strict: nil),
                .function(name: "calendar", description: nil, parameters: nil, strict: nil),
            ],
            toolChoice: .function(name: "calendar")
        )

        let input = try client.userInput(body: body)
        let tools = try #require(input.tools)
        let function = try #require(tools.first?["function"] as? [String: any Sendable])
        let messages = try modelMessages(from: input)
        let system = try #require(messages.first)

        #expect(tools.count == 1)
        #expect(function["name"] as? String == "calendar")
        #expect(system["role"] as? String == "system")
        #expect((system["content"] as? String)?.contains("Follow application policy.") == true)
        #expect((system["content"] as? String)?.contains("Call the calendar tool") == true)
    }

    @Test
    func `Tool history uses structured arguments and correlates result name`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(url: URL(fileURLWithPath: "/tmp/model"))
        let body = ChatRequestBody(messages: [
            .assistant(toolCalls: [.init(
                id: "call-1",
                function: .init(name: "weather", arguments: #"{"city":"Paris","days":2}"#)
            )]),
            .tool(content: .text("sunny"), toolCallID: "call-1"),
            .user(content: .text("Summarize it.")),
        ])

        let messages = try modelMessages(from: client.userInput(body: body))
        let assistant = try #require(messages.first)
        let calls = try #require(assistant["tool_calls"] as? [[String: any Sendable]])
        let function = try #require(calls.first?["function"] as? [String: any Sendable])
        let arguments = try #require(function["arguments"] as? [String: any Sendable])
        let result = try #require(messages.dropFirst().first)

        #expect(arguments["city"] as? String == "Paris")
        #expect(arguments["days"] as? Int == 2)
        #expect(result["name"] as? String == "weather")
        #expect(result["tool_call_id"] as? String == "call-1")
    }

    @Test
    func `Mistral tool call is emitted at EOS after preceding text`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let processor = ToolCallProcessor(format: .mistral)
        let generated = ChatCompletionChunk(choices: [
            .init(delta: .init(
                content: "Checking first. [TOOL_CALLS]weather[ARGS]{\"city\":\"Paris\"}"
            )),
        ])

        let streamed = responseChunks(from: generated, toolProcessor: processor)
        let finished = processor.processEOSOutputs().compactMap(responseChunk)

        #expect(streamed == [.text("Checking first. ")])
        let request = try #require(finished.first?.toolValue)
        #expect(request.name == "weather")
        #expect(request.args == #"{"city":"Paris"}"#)
    }

    @Test
    func `Single Mistral tool recovers bare EOS arguments`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        var stream = MLXToolStreamState(
            format: .mistral,
            tools: [[
                "type": "function",
                "function": ["name": "weather"] as [String: any Sendable],
            ]],
            toolChoice: .function(name: "weather")
        )
        let generated = ChatCompletionChunk(choices: [
            .init(delta: .init(content: #"{"city":"Paris"}"#)),
        ])

        #expect(stream.process(generated).isEmpty)
        let request = try #require(stream.finish().first?.toolValue)
        #expect(request.name == "weather")
        #expect(request.args == #"{"city":"Paris"}"#)
    }

    @Test
    func `Automatic Mistral choice preserves bare JSON as response text`() {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        var stream = MLXToolStreamState(
            format: .mistral,
            tools: [[
                "type": "function",
                "function": ["name": "weather"] as [String: any Sendable],
            ]],
            toolChoice: .auto
        )
        let generated = ChatCompletionChunk(choices: [
            .init(delta: .init(content: #"{"answer":"Paris"}"#)),
        ])

        #expect(stream.process(generated) == [.text(#"{"answer":"Paris"}"#)])
        #expect(stream.finish().isEmpty)
    }

    @Test
    func `Qwen XML call stays ordered after reasoning and response text`() throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let processor = ToolCallProcessor(format: .xmlFunction)
        let generated = ChatCompletionChunk(choices: [
            .init(delta: .init(
                content: "I will check. <tool_call><function=weather><parameter=city>Paris</parameter></function></tool_call>",
                reasoningContent: "The request needs current data."
            )),
        ])

        let chunks = responseChunks(from: generated, toolProcessor: processor)

        #expect(chunks.first == .reasoning("The request needs current data."))
        #expect(chunks.dropFirst().first == .text("I will check. "))
        let request = try #require(chunks.last?.toolValue)
        #expect(request.name == "weather")
        #expect(request.args == #"{"city":"Paris"}"#)
    }

    @Test(arguments: [
        ("<start_function_call>", ToolCallFormat.gemma),
        ("[TOOL_CALLS]name[ARGS]{}", ToolCallFormat.mistral),
        ("<tool_call><function=name><parameter=value>", ToolCallFormat.xmlFunction),
        ("<|tool_call_start|>", ToolCallFormat.lfm2),
        ("<tool_call>{\"name\":\"tool\"}</tool_call>", ToolCallFormat.json),
    ])
    func `Tool format is derived from the model chat template`(
        marker: String,
        expected: ToolCallFormat
    ) throws {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try marker.write(
            to: directory.appendingPathComponent("chat_template.jinja"),
            atomically: true,
            encoding: .utf8
        )

        #expect(MLXToolCallFormatDetector.detect(in: directory) == expected)
    }

    @Test
    func `Generation parameters clamp unsafe values`() {
        guard #available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *) else { return }
        let client = MLXChatClient(url: URL(fileURLWithPath: "/tmp/model"))

        let high = client.generateParameters(body: .init(
            maxCompletionTokens: 0,
            temperature: .infinity
        ))
        let low = client.generateParameters(body: .init(temperature: -1))

        #expect(high.maxTokens == 1)
        #expect(high.temperature == 0.6)
        #expect(low.temperature == 0)
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
    private func modelMessages(from input: UserInput) throws -> [[String: any Sendable]] {
        guard case let .messages(messages) = input.prompt else {
            throw MLXLocalModelAPITestError.expectedMessages
        }
        return messages
    }
}

private enum MLXLocalModelAPITestError: Error {
    case expectedMessages
}
