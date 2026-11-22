#if compiler(>=6.4)
    import Foundation
    import FoundationModels

    /// Streams replies from Apple's Private Cloud Compute model through the
    /// same prompt, transcript and tool bridge as `AppleIntelligenceChatClient`:
    /// a tool call is captured and handed back to the app as a `.tool` chunk,
    /// and the app runs the tool and sends its output in the next request.
    @available(iOS 27.0, macOS 27.0, macCatalyst 27.0, *)
    public final class PrivateCloudComputeChatClient: ChatService, @unchecked Sendable {
        public struct Configuration: Sendable {
            public var persona: String
            /// nil leaves the reasoning level to the model.
            public var reasoningDepth: PrivateCloudComputeReasoningDepth?

            public init(
                persona: String = "",
                reasoningDepth: PrivateCloudComputeReasoningDepth? = nil
            ) {
                self.persona = persona
                self.reasoningDepth = reasoningDepth
            }
        }

        public let errorCollector = ErrorCollector.new()

        let configuration: Configuration
        let model: PrivateCloudComputeModel

        public convenience init(configuration: Configuration = .init()) {
            self.init(configuration: configuration, model: .shared)
        }

        init(configuration: Configuration, model: PrivateCloudComputeModel) {
            self.configuration = configuration
            self.model = model
        }

        struct SessionContext {
            let session: LanguageModelSession
            let prompt: String
            let options: GenerationOptions
            let contextOptions: ContextOptions
        }

        static func reasoningLevel(
            for depth: PrivateCloudComputeReasoningDepth?
        ) -> ContextOptions.ReasoningLevel? {
            switch depth {
            case .light: .light
            case .moderate: .moderate
            case .deep: .deep
            case nil: nil
            }
        }

        func makeSessionContext(body: ChatRequestBody) throws -> SessionContext {
            let tools: [any Tool] = try body.selectedTools().map { tool -> any Tool in
                switch tool {
                case let .function(name, description, parameters, _):
                    try AppleIntelligenceToolProxy(
                        name: name,
                        description: description,
                        parameters: parameters
                    )
                }
            }

            let instructionText = AppleIntelligencePromptBuilder.makeInstructions(
                persona: configuration.persona,
                messages: body.messages,
                additionalDirectives: body.toolChoiceDirective.map { [$0] } ?? []
            )
            let prompt = AppleIntelligencePromptBuilder.makePrompt(from: body.messages)
            let history = AppleIntelligencePromptBuilder.makeHistory(from: body.messages)

            let session = if history.isEmpty {
                LanguageModelSession(
                    model: model.languageModel,
                    tools: tools,
                    instructions: instructionText
                )
            } else {
                LanguageModelSession(
                    model: model.languageModel,
                    tools: tools,
                    transcript: AppleIntelligencePromptBuilder.makeTranscript(
                        instructions: instructionText,
                        tools: tools,
                        history: history
                    )
                )
            }

            let temperature = body.temperature.flatMap { value in
                value.isFinite ? min(max(value, 0), 2) : nil
            }
            let maximumResponseTokens = body.maxCompletionTokens.flatMap { value in
                value > 0 ? value : nil
            }
            let options = GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maximumResponseTokens
            )
            let contextOptions = ContextOptions(
                reasoningLevel: Self.reasoningLevel(for: configuration.reasoningDepth)
            )

            return SessionContext(
                session: session,
                prompt: prompt,
                options: options,
                contextOptions: contextOptions
            )
        }

        /// The reasoning text in a stream snapshot. Apple's models may send
        /// reasoning entries that hold only a signature; those add nothing.
        static func reasoningText(in entries: some Collection<Transcript.Entry>) -> String {
            var text = ""
            for entry in entries {
                guard case let .reasoning(reasoning) = entry else { continue }
                for segment in reasoning.segments {
                    if case let .text(textSegment) = segment {
                        text += textSegment.content
                    }
                }
            }
            return text
        }

        public func streamingChat(
            body: ChatRequestBody
        ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
            // The availability says nothing about the network; that failure
            // arrives as `PrivateCloudComputeLanguageModel.Error.networkFailure`.
            if case let .unavailable(reason) = model.availabilityState {
                throw PrivateCloudComputeUnavailableError(reason: reason)
            }

            let context = try makeSessionContext(body: body)

            return AnyAsyncSequence(AsyncThrowingStream { continuation in
                let task = Task {
                    var textState = AppleIntelligenceStreamState()
                    var reasoningState = AppleIntelligenceStreamState()
                    do {
                        for try await snapshot in context.session.streamResponse(
                            to: context.prompt,
                            options: context.options,
                            contextOptions: context.contextOptions
                        ) {
                            let reasoning = Self.reasoningText(in: snapshot.transcriptEntries)
                            if let delta = reasoningState.delta(for: reasoning) {
                                continuation.yield(.reasoning(delta))
                            }
                            if let chunk = textState.textChunk(for: snapshot.content) {
                                continuation.yield(chunk)
                            }
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish()
                    } catch let error as LanguageModelSession.ToolCallError {
                        guard let captured = error.underlyingError as? AppleIntelligenceToolError,
                              case let .invocationCaptured(request) = captured
                        else {
                            continuation.finish(throwing: error)
                            return
                        }
                        continuation.yield(textState.toolChunk(for: request))
                        continuation.finish()
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
#endif
