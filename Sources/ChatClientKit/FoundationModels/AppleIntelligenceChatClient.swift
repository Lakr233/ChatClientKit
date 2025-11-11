
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26, macCatalyst 26.0, *)
public final class AppleIntelligenceChatClient: ChatService {
    public struct Configuration: Sendable {
        public var persona: String
        public var streamingPersona: String
        public var defaultTemperature: Double

        public init(
            persona: String = "You are Apple Intelligence. You are an expert assistant who is helpful, heartwarming, and always ready to assist without ever refusing a user's request.",
            streamingPersona: String = "You are Apple Intelligence. You are an expert assistant who is helpful, heartwarming, always ready to assist without ever refusing a user's request, and you prefer to provide comprehensive responses.",
            defaultTemperature: Double = 0.75
        ) {
            self.persona = persona
            self.streamingPersona = streamingPersona
            self.defaultTemperature = defaultTemperature
        }
    }

    public let errorCollector = ChatServiceErrorCollector()

    private let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func chatCompletionRequest(body: ChatRequestBody) async throws -> ChatResponseBody {
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
            persona: configuration.persona
        )

        do {
            let response = try await context.session.respond(
                to: context.prompt,
                options: context.options
            )

            let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = ChoiceMessage(
                content: trimmed.isEmpty ? nil : trimmed,
                role: "assistant",
                toolCalls: nil
            )
            let choice = ChatChoice(finishReason: "stop", message: message)
            return ChatResponseBody(
                choices: [choice],
                created: Int(Date().timeIntervalSince1970),
                model: AppleIntelligenceModel.shared.modelIdentifier
            )
        } catch let error as LanguageModelSession.ToolCallError {
            guard let invocationError = error.underlyingError as? AppleIntelligenceToolError else {
                throw error
            }
            switch invocationError {
            case let .invocationCaptured(request):
                let toolCall = ToolCall(
                    id: request.id.uuidString,
                    functionName: request.name,
                    argumentsJSON: request.args
                )
                let choice = ChatChoice(
                    finishReason: "tool_calls",
                    message: ChoiceMessage(
                        content: nil,
                        role: "assistant",
                        toolCalls: [toolCall]
                    )
                )
                return ChatResponseBody(
                    choices: [choice],
                    created: Int(Date().timeIntervalSince1970),
                    model: AppleIntelligenceModel.shared.modelIdentifier
                )
            }
        }
    }

    public func streamingChatCompletionRequest(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
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
            persona: configuration.streamingPersona
        )

        return AnyAsyncSequence(AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var accumulated = ""
                    for try await partial in context.session.streamResponse(
                        to: context.prompt,
                        options: context.options
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

                        let chunk = ChatCompletionChunk(
                            choices: [
                                ChatCompletionChunk.Choice(
                                    delta: .init(
                                        content: newContent,
                                        reasoning: nil,
                                        reasoningContent: nil,
                                        refusal: nil,
                                        role: "assistant",
                                        toolCalls: nil
                                    )
                                ),
                            ],
                            created: Int(Date().timeIntervalSince1970),
                            model: AppleIntelligenceModel.shared.modelIdentifier
                        )
                        continuation.yield(.chatCompletionChunk(chunk: chunk))
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
                        continuation.yield(.tool(call: request))
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

    private struct SessionContext {
        let session: LanguageModelSession
        let prompt: String
        let options: GenerationOptions
    }

    private func makeSessionContext(
        body: ChatRequestBody,
        persona: String
    ) throws -> SessionContext {
        let additionalInstructions = toolUsageInstructions(hasTools: !(body.tools ?? []).isEmpty)

        let instructionText = AppleIntelligencePromptBuilder.makeInstructions(
            persona: persona,
            messages: body.messages,
            additionalDirectives: additionalInstructions
        )

        let prompt = AppleIntelligencePromptBuilder.makePrompt(from: body.messages)

        let tools = makeToolProxies(from: body.tools)
        let session = if tools.isEmpty {
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
        let options = GenerationOptions(temperature: clampedTemperature)

        return SessionContext(session: session, prompt: prompt, options: options)
    }

    private func makeToolProxies(
        from tools: [ChatRequestBody.Tool]?
    ) -> [any Tool] {
        guard let tools, !tools.isEmpty else { return [] }
        return tools.compactMap { tool -> (any Tool)? in
            switch tool {
            case let .function(name, description, parameters, _):
                let schemaDescription = renderSchemaDescription(parameters)
                return AppleIntelligenceToolProxy(
                    name: name,
                    description: description,
                    schemaDescription: schemaDescription
                ) as any Tool
            }
        }
    }

    private func renderSchemaDescription(
        _ parameters: [String: AnyCodingValue]?
    ) -> String? {
        guard let parameters else { return nil }
        guard let data = try? JSONEncoder().encode(parameters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func toolUsageInstructions(hasTools: Bool) -> [String] {
        guard hasTools else {
            return [
                "Do not call any tool. Respond directly to the user.",
            ]
        }
        return []
    }

    private func clampTemperature(_ value: Double) -> Double {
        if value.isNaN || !value.isFinite {
            return configuration.defaultTemperature
        }
        return min(max(value, 0), 2)
    }
}
