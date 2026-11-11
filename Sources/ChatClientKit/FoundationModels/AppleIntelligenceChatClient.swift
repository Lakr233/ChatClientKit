
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
public class AppleIntelligenceChatClient: ChatService, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var persona: String
        public var streamingPersona: String
        public var defaultTemperature: Double

        public init(
            persona: String = "",
            streamingPersona: String = "",
            defaultTemperature: Double = 0.75
        ) {
            self.persona = persona
            self.streamingPersona = streamingPersona
            self.defaultTemperature = defaultTemperature
        }
    }

    public let errorCollector = ErrorCollector.new()

    let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func streamingChat(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try makeStreamingSequence(
            body: body,
            persona: configuration.streamingPersona
        )
    }

    struct SessionContext {
        let session: LanguageModelSession
        let prompt: String
        let options: GenerationOptions
    }

    func makeSessionContext(
        body: ChatRequestBody,
        persona: String
    ) throws -> SessionContext {
        let selectedTools = try body.selectedTools()
        let tools = try makeToolProxies(from: selectedTools)

        let instructionText = AppleIntelligencePromptBuilder.makeInstructions(
            persona: persona,
            messages: body.messages,
            additionalDirectives: body.toolChoiceDirective.map { [$0] } ?? []
        )

        let prompt = AppleIntelligencePromptBuilder.makePrompt(from: body.messages)
        let history = AppleIntelligencePromptBuilder.makeHistory(from: body.messages)

        let session = if !history.isEmpty {
            LanguageModelSession(
                tools: tools,
                transcript: AppleIntelligencePromptBuilder.makeTranscript(
                    instructions: instructionText,
                    tools: tools,
                    history: history
                )
            )
        } else if tools.isEmpty {
            LanguageModelSession(instructions: instructionText)
        } else {
            LanguageModelSession(
                tools: tools,
                instructions: instructionText
            )
        }

        let clampedTemperature = clampTemperature(
            body.temperature ?? configuration.defaultTemperature
        )
        let maximumResponseTokens = body.maxCompletionTokens.flatMap { value in
            value > 0 ? value : nil
        }
        let options = GenerationOptions(
            temperature: clampedTemperature,
            maximumResponseTokens: maximumResponseTokens
        )

        return SessionContext(session: session, prompt: prompt, options: options)
    }

    func makeToolProxies(
        from tools: [ChatRequestBody.Tool]
    ) throws -> [any Tool] {
        try tools.map { tool -> any Tool in
            switch tool {
            case let .function(name, description, parameters, _):
                return try AppleIntelligenceToolProxy(
                    name: name,
                    description: description,
                    parameters: parameters
                ) as any Tool
            }
        }
    }

    func clampTemperature(_ value: Double) -> Double {
        let fallback = configuration.defaultTemperature.isFinite
            ? configuration.defaultTemperature
            : 0.75
        guard value.isFinite else { return min(max(fallback, 0), 2) }
        return min(max(value, 0), 2)
    }

    func makeStreamingSequence(
        body: ChatRequestBody,
        persona: String
    ) throws -> AnyAsyncSequence<ChatResponseChunk> {
        guard AppleIntelligenceModel.shared.isAvailable else {
            throw NSError(
                domain: "AppleIntelligence",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Apple Intelligence is not available."),
                ]
            )
        }

        let context = try makeSessionContext(
            body: body,
            persona: persona
        )

        return AnyAsyncSequence(AsyncThrowingStream { continuation in
            let task = Task {
                var streamState = AppleIntelligenceStreamState()
                do {
                    for try await partial in context.session.streamResponse(
                        to: context.prompt,
                        options: context.options
                    ) {
                        if let chunk = streamState.textChunk(for: partial.content) {
                            continuation.yield(chunk)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as LanguageModelSession.ToolCallError {
                    guard let invocationError = error.underlyingError as? AppleIntelligenceToolError else {
                        continuation.finish(throwing: error)
                        return
                    }
                    switch invocationError {
                    case let .invocationCaptured(request):
                        continuation.yield(streamState.toolChunk(for: request))
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        })
    }
}

struct AppleIntelligenceStreamState {
    private var accumulatedText = ""

    mutating func textChunk(for fullText: String) -> ChatResponseChunk? {
        guard fullText.hasPrefix(accumulatedText) else {
            accumulatedText = fullText
            return nil
        }

        let deltaStart = fullText.index(
            fullText.startIndex,
            offsetBy: accumulatedText.count
        )
        let delta = String(fullText[deltaStart...])
        accumulatedText = fullText
        return delta.isEmpty ? nil : .text(delta)
    }

    func toolChunk(for request: ToolRequest) -> ChatResponseChunk {
        .tool(request)
    }
}
