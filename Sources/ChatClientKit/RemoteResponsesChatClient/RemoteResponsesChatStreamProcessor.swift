//
//  RemoteResponsesChatStreamProcessor.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation
import ServerEvent

struct RemoteResponsesChatStreamProcessor {
    let eventSourceFactory: EventSourceProducing
    let chunkDecoder: JSONDecoding
    let errorExtractor: RemoteResponsesChatErrorExtractor
    let postProcessor: PostProcessor?

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteResponsesChatErrorExtractor = RemoteResponsesChatErrorExtractor(),
        postProcessor: PostProcessor? = nil
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
        self.postProcessor = postProcessor
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void
    ) -> AnyAsyncSequence<ChatResponseChunk> {
        let stream = AsyncStream<ChatResponseChunk> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, postProcessor, request] in
                var toolCollector = ResponsesToolCallCollector()
                var outputMetadata: [String: OutputItemMetadata] = [:]
                var streamedTextItemIDs: Set<String> = []
                var finishReasonEmitted = false
                var chunkCount = 0
                var totalContentLength = 0
                var ignoredToolEvents: Set<String> = []
                var consecutivePostProcessFailures = 0

                let streamTask = eventSourceFactory.makeDataTask(for: request)

                eventLoop: for await event in streamTask.events() {
                    switch event {
                    case .open:
                        logger.info("responses stream connection opened.")
                    case let .error(error):
                        logger.error("received responses stream error: \(error.localizedDescription)")
                        await collectError(error)
                    case let .event(event):
                        guard let rawLine = event.data,
                              let data = rawLine.data(using: .utf8)
                        else {
                            continue
                        }
                        if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "[DONE]" {
                            logger.debug("received [DONE] from responses stream")
                            continue
                        }

                        if let decodeError = errorExtractor.extractError(from: data) {
                            await collectError(decodeError)
                            continue
                        }

                        // Scripting active — let JS produce the chunk.
                        if let postProcessor {
                            // Best-effort native parse to a PostProcessOutput for
                            // inherit=true path. On parse failure pass empty parsed.
                            var parsed = PostProcessOutput()
                            if let payload = try? chunkDecoder.decode(ResponsesStreamEvent.self, from: data) {
                                if let chunk = handle(
                                    payload: payload,
                                    toolCollector: &toolCollector,
                                    outputMetadata: &outputMetadata,
                                    streamedTextItemIDs: &streamedTextItemIDs,
                                    ignoredToolEvents: &ignoredToolEvents,
                                    finishEmitted: &finishReasonEmitted
                                ) {
                                    var reasoning: String?
                                    var content: String?
                                    for choice in chunk.choices {
                                        if let r = choice.delta.reasoningContent {
                                            reasoning = (reasoning ?? "") + r
                                        }
                                        if let c = choice.delta.content {
                                            content = (content ?? "") + c
                                        }
                                    }
                                    parsed = PostProcessOutput(reasoning: reasoning, content: content, toolCalls: nil)
                                }
                            }

                            let out: PostProcessOutput
                            do {
                                out = try postProcessor.process(parsed: parsed, rawLine: rawLine)
                            } catch {
                                await collectError(error)
                                consecutivePostProcessFailures += 1
                                if consecutivePostProcessFailures >= 3 {
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

                        // Native path (no scripting).
                        do {
                            let payload = try chunkDecoder.decode(ResponsesStreamEvent.self, from: data)

                            if let statusError = payload.asStatusError() {
                                await collectError(statusError)
                                finishReasonEmitted = true
                                continue
                            }

                            if let eventError = payload.asError() {
                                await collectError(eventError)
                                continue
                            }

                            if let chunk = handle(
                                payload: payload,
                                toolCollector: &toolCollector,
                                outputMetadata: &outputMetadata,
                                streamedTextItemIDs: &streamedTextItemIDs,
                                ignoredToolEvents: &ignoredToolEvents,
                                finishEmitted: &finishReasonEmitted
                            ) {
                                chunkCount += 1
                                for choice in chunk.choices {
                                    if let reasoning = choice.delta.reasoningContent {
                                        continuation.yield(.reasoning(reasoning))
                                    }
                                    if let content = choice.delta.content {
                                        totalContentLength += content.count
                                        continuation.yield(.text(content))
                                    }
                                }
                            }
                        } catch {
                            await collectError(error)
                        }
                    case .closed:
                        logger.info("responses stream connection closed.")
                    }
                }

                if !finishReasonEmitted {
                    let hasTools = toolCollector.hasPendingRequests
                    finishReasonEmitted = true
                    _ = hasTools // terminal reason only; no chunk emitted
                }

                // Native-only tail: with scripting on, JS already drove tool yielding.
                if postProcessor == nil {
                    let pendingCalls = toolCollector.finalizeRequests()
                    for call in pendingCalls {
                        continuation.yield(.tool(call))
                    }
                    logger.info("responses streaming completed: received \(chunkCount) chunks, total content length: \(totalContentLength), tool calls: \(pendingCalls.count), ignored tool-like events: \(ignoredToolEvents.count)")
                } else {
                    logger.info("responses streaming completed via scripting: received \(chunkCount) chunks, total content length: \(totalContentLength)")
                }
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }
}

extension RemoteResponsesChatStreamProcessor {
    struct OutputItemMetadata {
        let role: String
        let outputIndex: Int?
    }

    func handle(
        payload: ResponsesStreamEvent,
        toolCollector: inout ResponsesToolCallCollector,
        outputMetadata: inout [String: OutputItemMetadata],
        streamedTextItemIDs: inout Set<String>,
        ignoredToolEvents: inout Set<String>,
        finishEmitted: inout Bool
    ) -> ChatCompletionChunk? {
        switch payload.kind {
        case .outputTextDelta:
            guard let delta = payload.delta else { return nil }
            if let itemID = payload.itemID {
                streamedTextItemIDs.insert(itemID)
            }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: delta
            )
        case .outputTextDone:
            let content = resolvedFinalText(from: payload, streamedTextItemIDs: &streamedTextItemIDs)
            guard content != nil else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: content
            )
        case .reasoningTextDelta:
            guard let delta = payload.delta else { return nil }
            if let itemID = payload.itemID {
                streamedTextItemIDs.insert(itemID)
            }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: delta
            )
        case .reasoningTextDone:
            let content = resolvedFinalText(from: payload, streamedTextItemIDs: &streamedTextItemIDs)
            guard content != nil else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: content
            )
        case .refusalDelta:
            guard let delta = payload.delta else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: delta
            )
        case .refusalDone:
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: payload.refusal ?? payload.text ?? payload.delta
            )
        case .functionCallArgumentsDelta:
            toolCollector.appendDelta(
                for: payload.itemID,
                name: payload.name,
                delta: payload.delta,
                outputIndex: payload.outputIndex
            )
            return nil
        case .functionCallArgumentsDone:
            toolCollector.finalize(
                for: payload.itemID,
                name: payload.name,
                arguments: payload.arguments,
                outputIndex: payload.outputIndex
            )
            return nil
        case .outputItemAdded:
            if let item = payload.item {
                toolCollector.observe(item: item)
                if let id = item.id ?? payload.itemID {
                    outputMetadata[id] = OutputItemMetadata(
                        role: item.role ?? "assistant",
                        outputIndex: payload.outputIndex
                    )
                }
            }
            return nil
        case .outputItemDone:
            if let item = payload.item {
                toolCollector.observe(item: item)
                if let id = item.id ?? payload.itemID {
                    outputMetadata[id] = OutputItemMetadata(
                        role: item.role ?? "assistant",
                        outputIndex: payload.outputIndex
                    )
                }
            }
            return nil
        case .reasoningSummaryTextDelta:
            guard let delta = payload.delta else { return nil }
            if let itemID = payload.itemID {
                let summaryKey = "\(itemID)_summary_\(payload.summaryIndex ?? 0)"
                streamedTextItemIDs.insert(summaryKey)
            }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: delta
            )
        case .reasoningSummaryTextDone:
            if let itemID = payload.itemID {
                let summaryKey = "\(itemID)_summary_\(payload.summaryIndex ?? 0)"
                if streamedTextItemIDs.contains(summaryKey) {
                    return nil
                }
            }
            guard let text = payload.text, !text.isEmpty else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: text
            )
        case .responseCompleted:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: nil
            )
        case .responseFailed:
            finishEmitted = true
            return nil
        case .responseIncomplete:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: nil
            )
        case .error:
            return nil
        case .responseCreated,
             .responseInProgress,
             .responseQueued,
             .contentPartAdded,
             .reasoningSummaryPartAdded,
             .outputTextAnnotationAdded,
             .unknown,
             .contentPartDone:
            if payload.isToolLike {
                ignoredToolEvents.insert(payload.type)
            }
            return nil
        case .reasoningSummaryPartDone:
            return nil
        }
    }

    func makeChunk(
        payload: ResponsesStreamEvent,
        outputMetadata: [String: OutputItemMetadata],
        content: String? = nil,
        reasoning: String? = nil
    ) -> ChatCompletionChunk {
        let role = payload.itemID.flatMap { outputMetadata[$0]?.role } ?? "assistant"
        let choice = ChatCompletionChunk.Choice(
            delta: .init(
                content: content,
                reasoningContent: reasoning,
                role: role
            ),
            index: payload.outputIndex
        )
        return ChatCompletionChunk(choices: [choice])
    }

    func resolvedFinalText(
        from payload: ResponsesStreamEvent,
        streamedTextItemIDs: inout Set<String>
    ) -> String? {
        guard let text = payload.text, !text.isEmpty else { return nil }
        guard let itemID = payload.itemID else { return text }
        if streamedTextItemIDs.contains(itemID) {
            return nil
        }
        streamedTextItemIDs.insert(itemID)
        return text
    }
}

struct ResponsesStreamEvent: Decodable {
    enum Kind: String {
        case outputTextDelta = "response.output_text.delta"
        case outputTextDone = "response.output_text.done"
        case reasoningTextDelta = "response.reasoning_text.delta"
        case reasoningTextDone = "response.reasoning_text.done"
        case refusalDelta = "response.refusal.delta"
        case refusalDone = "response.refusal.done"
        case functionCallArgumentsDelta = "response.function_call_arguments.delta"
        case functionCallArgumentsDone = "response.function_call_arguments.done"
        case outputItemAdded = "response.output_item.added"
        case outputItemDone = "response.output_item.done"
        case contentPartAdded = "response.content_part.added"
        case contentPartDone = "response.content_part.done"
        case reasoningSummaryPartAdded = "response.reasoning_summary_part.added"
        case reasoningSummaryPartDone = "response.reasoning_summary_part.done"
        case reasoningSummaryTextDelta = "response.reasoning_summary_text.delta"
        case reasoningSummaryTextDone = "response.reasoning_summary_text.done"
        case outputTextAnnotationAdded = "response.output_text.annotation.added"
        case responseCreated = "response.created"
        case responseInProgress = "response.in_progress"
        case responseQueued = "response.queued"
        case responseCompleted = "response.completed"
        case responseFailed = "response.failed"
        case responseIncomplete = "response.incomplete"
        case error
        case unknown
    }

    let type: String
    let delta: String?
    let text: String?
    let name: String?
    let arguments: String?
    let itemID: String?
    let outputIndex: Int?
    let contentIndex: Int?
    let response: ResponsesAPIResponse?
    let item: ResponsesOutputItem?
    let part: ResponsesContentPart?
    let error: ResponsesErrorPayload?
    let message: String?
    let code: String?
    let summaryIndex: Int?
    let refusal: String?

    var kind: Kind {
        switch type {
        case "response.tool_call_arguments.delta":
            .functionCallArgumentsDelta
        case "response.tool_call_arguments.done":
            .functionCallArgumentsDone
        default:
        Kind(rawValue: type) ?? .unknown
        }
    }

    enum CodingKeys: String, CodingKey {
        case type
        case delta
        case text
        case name
        case arguments
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case response
        case item
        case part
        case error
        case message
        case code
        case summaryIndex = "summary_index"
        case refusal
    }

    func asError() -> Swift.Error? {
        guard kind == .error else { return nil }
        if let error {
            return NSError(
                domain: "Server Error",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: error.message ?? "Unknown error"]
            )
        }
        return NSError(
            domain: "Server Error",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]
        )
    }

    func asStatusError() -> Swift.Error? {
        switch kind {
        case .responseFailed:
            if let message = response?.error?.message ?? response?.status {
                return NSError(domain: "Server Error", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
            }
            return NSError(domain: "Server Error", code: 0, userInfo: [NSLocalizedDescriptionKey: "Response did not complete"])
        default:
            return nil
        }
    }

    var isToolLike: Bool {
        type.contains("_call") || type.contains("tool.")
    }

    func placeholderToolCall() -> ToolRequest? {
        guard isToolLike else { return nil }
        let identifier = itemID ?? UUID().uuidString
        let args = arguments ?? delta ?? text ?? message ?? "{}"
        return ToolRequest(id: identifier, name: type, args: args)
    }
}
