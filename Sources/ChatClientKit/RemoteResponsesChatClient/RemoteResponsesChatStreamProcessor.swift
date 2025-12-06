//
//  RemoteResponsesChatStreamProcessor.swift
//  ChatClientKit
//
//  Created by Henri on 2025/12/2.
//

import Foundation
import ServerEvent

struct RemoteResponsesChatStreamProcessor {
    private let eventSourceFactory: EventSourceProducing
    private let chunkDecoder: JSONDecoding
    private let errorExtractor: RemoteResponsesChatErrorExtractor

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteResponsesChatErrorExtractor = RemoteResponsesChatErrorExtractor(),
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void,
    ) -> AnyAsyncSequence<ChatServiceStreamObject> {
        let stream = AsyncStream<ChatServiceStreamObject> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, request] in
                var toolCollector = ResponsesToolCallCollector()
                var outputMetadata: [String: OutputItemMetadata] = [:]
                var streamedTextItemIDs: Set<String> = []
                var finishReasonEmitted = false
                var chunkCount = 0
                var totalContentLength = 0
                var ignoredToolEvents: Set<String> = []

                let streamTask = eventSourceFactory.makeDataTask(for: request)

                for await event in streamTask.events() {
                    switch event {
                    case .open:
                        logger.info("responses stream connection opened.")
                    case let .error(error):
                        logger.error("received responses stream error: \(error.localizedDescription)")
                        await collectError(error)
                    case let .event(event):
                        guard let data = event.data?.data(using: .utf8) else {
                            continue
                        }
                        if let text = String(data: data, encoding: .utf8),
                           text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "[DONE]"
                        {
                            logger.debug("received [DONE] from responses stream")
                            continue
                        }

                        if let decodeError = errorExtractor.extractError(from: data) {
                            await collectError(decodeError)
                            continue
                        }

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
                                finishEmitted: &finishReasonEmitted,
                            ) {
                                chunkCount += 1
                                totalContentLength += chunk.choices
                                    .compactMap(\.delta.content)
                                    .map(\.count)
                                    .reduce(0, +)
                                continuation.yield(.chatCompletionChunk(chunk: chunk))
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
                    let terminalChoice = ChatCompletionChunk.Choice(
                        delta: .init(content: nil, reasoningContent: nil, refusal: nil, role: "assistant"),
                        finishReason: finishReason(for: .responseCompleted, hasToolCalls: hasTools),
                        index: nil,
                    )
                    continuation.yield(.chatCompletionChunk(chunk: ChatCompletionChunk(choices: [terminalChoice])))
                }

                let pendingCalls = toolCollector.finalizeRequests()
                for call in pendingCalls {
                    continuation.yield(.tool(call: call))
                }
                logger.info("responses streaming completed: received \(chunkCount) chunks, total content length: \(totalContentLength), tool calls: \(pendingCalls.count), ignored tool-like events: \(ignoredToolEvents.count)")
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }
}

private extension RemoteResponsesChatStreamProcessor {
    struct OutputItemMetadata: Sendable {
        let role: String
        let outputIndex: Int?
    }

    func handle(
        payload: ResponsesStreamEvent,
        toolCollector: inout ResponsesToolCallCollector,
        outputMetadata: inout [String: OutputItemMetadata],
        streamedTextItemIDs: inout Set<String>,
        ignoredToolEvents: inout Set<String>,
        finishEmitted: inout Bool,
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
                content: delta,
                finishReason: nil,
            )
        case .outputTextDone:
            let content = resolvedFinalText(from: payload, streamedTextItemIDs: &streamedTextItemIDs)
            guard content != nil else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: content,
                finishReason: nil,
            )
        case .reasoningTextDelta:
            guard let delta = payload.delta else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: delta,
                finishReason: nil,
            )
        case .reasoningTextDone:
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: payload.text ?? payload.delta,
                finishReason: nil,
            )
        case .refusalDelta:
            guard let delta = payload.delta else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                refusal: delta,
                finishReason: nil,
            )
        case .refusalDone:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                refusal: payload.refusal ?? payload.text ?? payload.delta,
                finishReason: finishReason(for: payload.kind, hasToolCalls: toolCollector.hasPendingRequests),
            )
        case .functionCallArgumentsDelta:
            toolCollector.appendDelta(
                for: payload.itemID,
                name: payload.name,
                delta: payload.delta,
                outputIndex: payload.outputIndex,
            )
            return nil
        case .functionCallArgumentsDone:
            toolCollector.finalize(
                for: payload.itemID,
                name: payload.name,
                arguments: payload.arguments,
                outputIndex: payload.outputIndex,
            )
            return nil
        case .outputItemAdded:
            if let item = payload.item {
                toolCollector.observe(item: item)
                if let id = item.id ?? payload.itemID {
                    outputMetadata[id] = OutputItemMetadata(
                        role: item.role ?? "assistant",
                        outputIndex: payload.outputIndex,
                    )
                }
            }
            return nil
        case .outputItemDone:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: nil,
                finishReason: finishReason(for: payload.kind, hasToolCalls: toolCollector.hasPendingRequests),
            )
        case .reasoningSummaryTextDelta:
            guard let delta = payload.delta else { return nil }
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: delta,
                finishReason: nil,
            )
        case .reasoningSummaryTextDone:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: payload.text,
                finishReason: finishReason(for: payload.kind, hasToolCalls: toolCollector.hasPendingRequests),
            )
        case .responseCompleted:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: nil,
                finishReason: finishReason(for: payload.kind, hasToolCalls: toolCollector.hasPendingRequests),
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
                content: nil,
                finishReason: finishReason(for: payload.kind, hasToolCalls: toolCollector.hasPendingRequests),
            )
        case .error:
            return nil
        case .contentPartAdded,
             .reasoningSummaryPartAdded,
             .outputTextAnnotationAdded,
             .unknown,
             .contentPartDone:
            if payload.isToolLike {
                ignoredToolEvents.insert(payload.type)
            }
            return nil
        case .reasoningSummaryPartDone:
            return makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: payload.part?.text ?? payload.text,
                finishReason: nil,
            )
        }
    }

    func makeChunk(
        payload: ResponsesStreamEvent,
        outputMetadata: [String: OutputItemMetadata],
        content: String? = nil,
        reasoning: String? = nil,
        refusal: String? = nil,
        finishReason: String?,
    ) -> ChatCompletionChunk {
        let role = payload.itemID.flatMap { outputMetadata[$0]?.role } ?? "assistant"
        let choice = ChatCompletionChunk.Choice(
            delta: .init(
                content: content,
                reasoningContent: reasoning,
                refusal: refusal,
                role: role,
            ),
            finishReason: finishReason,
            index: payload.outputIndex,
        )
        return ChatCompletionChunk(choices: [choice])
    }

    func resolvedFinalText(
        from payload: ResponsesStreamEvent,
        streamedTextItemIDs: inout Set<String>,
    ) -> String? {
        guard let text = payload.text, !text.isEmpty else { return nil }
        guard let itemID = payload.itemID else { return text }
        if streamedTextItemIDs.contains(itemID) {
            return nil
        }
        streamedTextItemIDs.insert(itemID)
        return text
    }

    func finishReason(for kind: ResponsesStreamEvent.Kind, hasToolCalls: Bool) -> String? {
        let stopOrTool = hasToolCalls ? "tool_calls" : "stop"
        switch kind {
        case .refusalDone:
            return "refusal"
        case .responseIncomplete:
            return "length"
        case .responseCompleted:
            return stopOrTool
        case .outputItemDone:
            return stopOrTool
        case .reasoningSummaryTextDone:
            return stopOrTool
        case .reasoningSummaryPartDone:
            return stopOrTool
        case .outputTextDone:
            return stopOrTool
        default:
            return "stop"
        }
    }
}

private struct ResponsesStreamEvent: Decodable {
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

    var kind: Kind { Kind(rawValue: type) ?? .unknown }

    private enum CodingKeys: String, CodingKey {
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
                userInfo: [NSLocalizedDescriptionKey: error.message ?? "Unknown error"],
            )
        }
        return NSError(
            domain: "Server Error",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"],
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

    func placeholderToolCall() -> ToolCallRequest? {
        guard isToolLike else { return nil }
        let identifier = itemID ?? UUID().uuidString
        let args = arguments ?? delta ?? text ?? message ?? "{}"
        return ToolCallRequest(id: identifier, name: type, args: args)
    }
}
