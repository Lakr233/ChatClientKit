#if compiler(>=6.4)
    import Foundation
    internal import FoundationModels

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
            /// Called for each stage of a request, so the app can log what
            /// the framework did. Called from the streaming task.
            public var eventHandler: (@Sendable (PrivateCloudComputeStreamEvent) -> Void)?

            public init(
                persona: String = "",
                reasoningDepth: PrivateCloudComputeReasoningDepth? = nil,
                eventHandler: (@Sendable (PrivateCloudComputeStreamEvent) -> Void)? = nil
            ) {
                self.persona = persona
                self.reasoningDepth = reasoningDepth
                self.eventHandler = eventHandler
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
            let historyEntries: Int
            /// Tools passed to the session.
            let tools: Int
            /// Names of tools left out because their schema could not be
            /// converted; the request goes on without them.
            let skippedTools: [String]
            let instructionsLength: Int
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
            let conversion = try AppleIntelligenceToolProxy.makeProxies(
                from: body.selectedTools(),
                toolChoice: body.toolChoice
            )
            let tools = conversion.tools

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
                contextOptions: contextOptions,
                historyEntries: history.count,
                tools: tools.count,
                skippedTools: conversion.skipped.map(\.name),
                instructionsLength: instructionText.count
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
            let report = configuration.eventHandler ?? { _ in }
            report(.sessionCreated(
                historyEntries: context.historyEntries,
                tools: context.tools,
                instructionsLength: context.instructionsLength,
                promptLength: context.prompt.count,
                reasoningDepth: configuration.reasoningDepth
            ))

            return AnyAsyncSequence(AsyncThrowingStream { continuation in
                let task = Task {
                    var textState = AppleIntelligenceStreamState()
                    var reasoningState = AppleIntelligenceStreamState()
                    var snapshots = 0
                    do {
                        report(.requestSent)
                        // Each snapshot holds everything generated so far
                        // ("a response stream that produces aggregated
                        // tokens"), so only the growth is forwarded.
                        for try await snapshot in context.session.streamResponse(
                            to: context.prompt,
                            options: context.options,
                            contextOptions: context.contextOptions
                        ) {
                            snapshots += 1
                            let reasoning = Self.reasoningText(in: snapshot.transcriptEntries)
                            report(.snapshot(
                                index: snapshots,
                                contentLength: snapshot.content.count,
                                reasoningLength: reasoning.count,
                                transcriptEntries: snapshot.transcriptEntries.count
                            ))
                            Self.reportRewrite(of: .reasoning, from: reasoningState, to: reasoning, report)
                            if let delta = reasoningState.delta(for: reasoning) {
                                continuation.yield(.reasoning(delta))
                            }
                            Self.reportRewrite(of: .content, from: textState, to: snapshot.content, report)
                            if let chunk = textState.textChunk(for: snapshot.content) {
                                continuation.yield(chunk)
                            }
                        }
                        report(.finished(
                            snapshots: snapshots,
                            contentLength: textState.accumulatedText.count,
                            reasoningLength: reasoningState.accumulatedText.count
                        ))
                        continuation.finish()
                    } catch is CancellationError {
                        report(.cancelled(snapshots: snapshots))
                        continuation.finish()
                    } catch let error as LanguageModelSession.ToolCallError {
                        guard let captured = error.underlyingError as? AppleIntelligenceToolError,
                              case let .invocationCaptured(request) = captured
                        else {
                            report(.failed(snapshots: snapshots, error: error))
                            continuation.finish(throwing: error)
                            return
                        }
                        report(.toolCallCaptured(name: request.name))
                        continuation.yield(textState.toolChunk(for: request))
                        continuation.finish()
                    } catch {
                        report(.failed(snapshots: snapshots, error: error))
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { _ in
                    task.cancel()
                }
            })
        }

        static func reportRewrite(
            of field: PrivateCloudComputeStreamEvent.Field,
            from state: AppleIntelligenceStreamState,
            to fullText: String,
            _ report: (PrivateCloudComputeStreamEvent) -> Void
        ) {
            guard !fullText.hasPrefix(state.accumulatedText) else { return }
            report(.snapshotRewritten(
                field: field,
                previousLength: state.accumulatedText.count,
                newLength: fullText.count
            ))
        }
    }
#endif
