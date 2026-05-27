//
//  RemoteCompletionsChatStreamProcessor.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation
import ServerEvent

struct RemoteCompletionsChatStreamProcessor {
    let eventSourceFactory: EventSourceProducing
    let chunkDecoder: JSONDecoding
    let errorExtractor: RemoteCompletionsChatErrorExtractor
    let reasoningParser: CompletionReasoningDecoder
    let postProcessor: PostProcessor?

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteCompletionsChatErrorExtractor = RemoteCompletionsChatErrorExtractor(),
        reasoningParser: CompletionReasoningDecoder = .init(),
        postProcessor: PostProcessor? = nil
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
        self.reasoningParser = reasoningParser
        self.postProcessor = postProcessor
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void
    ) -> AnyAsyncSequence<ChatResponseChunk> {
        let eventSourceFactory = eventSourceFactory
        let chunkDecoder = chunkDecoder
        let errorExtractor = errorExtractor
        let reasoningParser = reasoningParser
        let postProcessor = postProcessor

        let stream = AsyncStream<ChatResponseChunk> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, reasoningParser, postProcessor, request] in
                var canDecodeReasoningContent = true
                var reducer = ReasoningStreamReducer(parser: reasoningParser)
                let toolCallCollector = CompletionToolCollector()
                var chunkCount = 0
                var totalContentLength = 0
                // post_process 连续失败计数(plan §7,Round 2 codex HIGH #7)
                var consecutivePostProcessFailures = 0

                let streamTask = eventSourceFactory.makeDataTask(for: request)

                eventLoop: for await event in streamTask.events() {
                    switch event {
                    case .open:
                        logger.info("connection was opened.")
                    case let .error(error):
                        logger.error("received an error: \(error)")
                        await collectError(error)
                    case let .event(event):
                        guard let rawLine = event.data,
                              let data = rawLine.data(using: .utf8)
                        else {
                            continue
                        }
                        if rawLine.lowercased() == "[done]" {
                            logger.debug("received done from upstream")
                            continue
                        }

                        // Path A: scripting active — let JS produce
                        // (reasoning, content, tool_calls).
                        if let postProcessor {
                            let parsed = nativeParse(
                                data: data,
                                chunkDecoder: chunkDecoder,
                                reasoningParser: reasoningParser,
                                canDecodeReasoning: &canDecodeReasoningContent,
                                reducer: &reducer
                            )
                            let out: PostProcessOutput
                            do {
                                out = try postProcessor.process(
                                    parsed: parsed ?? PostProcessOutput(),
                                    rawLine: rawLine
                                )
                            } catch {
                                await collectError(error)
                                consecutivePostProcessFailures += 1
                                if consecutivePostProcessFailures >= 3 {
                                    // Round 1 impl-review MED #6 fix:
                                    // surface a clear terminal error so
                                    // callers don't see partial output as
                                    // success. AsyncStream can't throw, so
                                    // we collect the error before finish().
                                    await collectError(ScriptingStreamError.consecutivePostProcessFailures(
                                        count: consecutivePostProcessFailures, last: error
                                    ))
                                    continuation.finish()
                                    break eventLoop
                                }
                                continue
                            }
                            consecutivePostProcessFailures = 0
                            chunkCount += 1
                            if let r = out.reasoning, !r.isEmpty {
                                continuation.yield(.reasoning(r))
                            }
                            if let c = out.content {
                                totalContentLength += c.count
                                continuation.yield(.text(c))
                            }
                            for t in out.toolCalls ?? [] {
                                continuation.yield(.tool(ToolRequest(id: t.id, name: t.name, args: t.args)))
                            }
                            continue
                        }

                        // Path B: native (no scripting).
                        do {
                            var response = try chunkDecoder.decode(ChatCompletionChunk.self, from: data)

                            let reasoningContent = [
                                response.choices.map(\.delta).compactMap(\.reasoning),
                                response.choices.map(\.delta).compactMap(\.reasoningContent),
                            ].flatMap(\.self).filter { !$0.isEmpty }
                            if canDecodeReasoningContent, !reasoningContent.isEmpty {
                                canDecodeReasoningContent = false
                            }

                            if canDecodeReasoningContent {
                                let contentSegments = response.choices.map(\.delta).compactMap(\.content)
                                reducer.process(contentSegments: contentSegments, into: &response)
                            }

                            for delta in response.choices {
                                if let toolCalls = delta.delta.toolCalls {
                                    for toolDelta in toolCalls {
                                        toolCallCollector.submit(delta: toolDelta)
                                    }
                                }
                                if let content = delta.delta.content {
                                    totalContentLength += content.count
                                }
                            }

                            chunkCount += 1
                            for choice in response.choices {
                                let reasoning = choice.delta.reasoningContent ?? choice.delta.reasoning
                                if let reasoning, !reasoning.isEmpty {
                                    continuation.yield(.reasoning(reasoning))
                                }
                                if let content = choice.delta.content {
                                    continuation.yield(.text(content))
                                }
                                if let images = choice.delta.images {
                                    for image in images {
                                        if let parsed = parseDataURL(image.imageURL.url) {
                                            continuation.yield(.image(.init(data: parsed.data, mimeType: parsed.mimeType)))
                                        }
                                    }
                                }
                            }
                        } catch {
                            if let text = String(data: data, encoding: .utf8) {
                                logger.log("text content associated with this error \(text)")
                            }
                            await collectError(error)
                        }

                        if let decodeError = errorExtractor.extractError(from: data) {
                            await collectError(decodeError)
                        }
                    case .closed:
                        logger.info("connection was closed.")
                    }
                }

                // Native-path-only: drain reducer + tool collector. With
                // scripting enabled, the JS is responsible for emitting
                // any leftover state in its own chunks.
                if postProcessor == nil {
                    for leftover in reducer.flushRemaining() {
                        for choice in leftover.choices {
                            let reasoning = choice.delta.reasoningContent ?? choice.delta.reasoning
                            if let reasoning, !reasoning.isEmpty {
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = choice.delta.content {
                                continuation.yield(.text(content))
                            }
                        }
                    }

                    toolCallCollector.finalizeCurrentDeltaContent()
                    for call in toolCallCollector.pendingRequests {
                        continuation.yield(.tool(call))
                    }
                    logger.info("streaming completed: received \(chunkCount) chunks, total content length: \(totalContentLength), tool calls: \(toolCallCollector.pendingRequests.count)")
                } else {
                    logger.info("streaming completed via scripting: received \(chunkCount) chunks, total content length: \(totalContentLength)")
                }
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }
}

/// Decode one SSE-data chunk into a `PostProcessOutput` for inherit=true
/// path. Returns nil if the chunk doesn't parse (silently swallowed —
/// inherit=true scripts get an empty `parsed` and can fall back to
/// `chatSession` or other state).
private func nativeParse(
    data: Data,
    chunkDecoder: JSONDecoding,
    reasoningParser _: CompletionReasoningDecoder,
    canDecodeReasoning: inout Bool,
    reducer: inout ReasoningStreamReducer
) -> PostProcessOutput? {
    guard var response = try? chunkDecoder.decode(ChatCompletionChunk.self, from: data) else {
        return nil
    }

    let reasoningContent = [
        response.choices.map(\.delta).compactMap(\.reasoning),
        response.choices.map(\.delta).compactMap(\.reasoningContent),
    ].flatMap(\.self).filter { !$0.isEmpty }
    if canDecodeReasoning, !reasoningContent.isEmpty {
        canDecodeReasoning = false
    }
    if canDecodeReasoning {
        let contentSegments = response.choices.map(\.delta).compactMap(\.content)
        reducer.process(contentSegments: contentSegments, into: &response)
    }

    var reasoning: String?
    var content: String?
    var toolCalls: [PostProcessOutput.ToolCall] = []
    for choice in response.choices {
        if let r = choice.delta.reasoningContent ?? choice.delta.reasoning, !r.isEmpty {
            reasoning = (reasoning ?? "") + r
        }
        if let c = choice.delta.content {
            content = (content ?? "") + c
        }
        for t in choice.delta.toolCalls ?? [] {
            if let fn = t.function, let name = fn.name {
                toolCalls.append(.init(
                    id: t.id ?? UUID().uuidString,
                    name: name,
                    args: fn.arguments ?? "{}"
                ))
            }
        }
    }
    return PostProcessOutput(
        reasoning: reasoning,
        content: content,
        toolCalls: toolCalls.isEmpty ? nil : toolCalls
    )
}

private func parseDataURL(_ text: String) -> (data: Data, mimeType: String?)? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.lowercased().hasPrefix("data:") {
        let parts = trimmed.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let header = parts[0] // data:image/png;base64
        let body = parts[1]
        let mimeType = header
            .replacingOccurrences(of: "data:", with: "")
            .replacingOccurrences(of: ";base64", with: "")
        guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { return nil }
        return (decoded, mimeType.isEmpty ? nil : mimeType)
    }

    if let decoded = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters) {
        return (decoded, nil)
    }

    return nil
}
