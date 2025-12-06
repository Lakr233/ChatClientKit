
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
            defaultTemperature: Double = 0.75,
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
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        try makeStreamingSequence(
            body: body,
            persona: configuration.streamingPersona,
        )
    }

    struct SessionContext {
        let session: LanguageModelSession
        let prompt: String
        let options: GenerationOptions
    }

    func makeSessionContext(
        body: ChatRequestBody,
        persona: String,
    ) throws -> SessionContext {
        let additionalInstructions = toolUsageInstructions(hasTools: !(body.tools ?? []).isEmpty)

        let instructionText = AppleIntelligencePromptBuilder.makeInstructions(
            persona: persona,
            messages: body.messages,
            additionalDirectives: additionalInstructions,
        )

        let prompt = AppleIntelligencePromptBuilder.makePrompt(from: body.messages)

        let tools = makeToolProxies(from: body.tools)
        let session = if tools.isEmpty {
            LanguageModelSession(instructions: instructionText)
        } else {
            LanguageModelSession(
                tools: tools,
                instructions: instructionText,
            )
        }

        let clampedTemperature = clampTemperature(
            body.temperature ?? configuration.defaultTemperature,
        )
        let options = GenerationOptions(temperature: clampedTemperature)

        return SessionContext(session: session, prompt: prompt, options: options)
    }

    func makeToolProxies(
        from tools: [ChatRequestBody.Tool]?,
    ) -> [any Tool] {
        guard let tools, !tools.isEmpty else { return [] }
        return tools.compactMap { tool -> (any Tool)? in
            switch tool {
            case let .function(name, description, parameters, _):
                let schemaDescription = renderSchemaDescription(parameters)
                return AppleIntelligenceToolProxy(
                    name: name,
                    description: description,
                    schemaDescription: schemaDescription,
                ) as any Tool
            }
        }
    }

    func renderSchemaDescription(
        _ parameters: [String: AnyCodingValue]?,
    ) -> String? {
        guard let parameters else { return nil }
        guard let data = try? JSONEncoder().encode(parameters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func toolUsageInstructions(hasTools: Bool) -> [String] {
        guard hasTools else {
            return [
                "No tools are available for this task, so answer the user directly without attempting any tool calls.",
            ]
        }
        return [
            "Explain why you intend to call a tool and what you expect it to produce before making the request, only use one when it truly helps the user, and feel free to proceed without any tool if that is better.",
        ]
    }

    func clampTemperature(_ value: Double) -> Double {
        if value.isNaN || !value.isFinite {
            return configuration.defaultTemperature
        }
        return min(max(value, 0), 2)
    }

    func makeStreamingSequence(
        body: ChatRequestBody,
        persona: String,
    ) throws -> AnyAsyncSequence<ChatResponseChunk> {
        guard AppleIntelligenceModel.shared.isAvailable else {
            throw NSError(
                domain: "AppleIntelligence",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Apple Intelligence is not available."),
                ],
            )
        }

        let context = try makeSessionContext(
            body: body,
            persona: persona,
        )

        return AnyAsyncSequence(AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var accumulated = ""
                    for try await partial in context.session.streamResponse(
                        to: context.prompt,
                        options: context.options,
                    ) {
                        let fullText = partial.content
                        guard fullText.count >= accumulated.count else {
                            accumulated = ""
                            continue
                        }

                        let deltaStart = fullText.index(fullText.startIndex, offsetBy: accumulated.count)
                        let newContent = String(fullText[deltaStart...])
                        accumulated = fullText

                        guard !newContent.isEmpty else { continue }

                        continuation.yield(.text(newContent))
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
                        continuation.yield(.tool(request))
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
