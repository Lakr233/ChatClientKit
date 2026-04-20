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
    let responseModifiers: [String]
    let environments: [String: Any]

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteResponsesChatErrorExtractor = RemoteResponsesChatErrorExtractor(),
        responseModifiers: [String] = [],
        environments: [String: Any] = [:]
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
        self.responseModifiers = responseModifiers
        self.environments = environments
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void
    ) -> AnyAsyncSequence<ChatResponseChunk> {
        let responseModifiers = responseModifiers
        let runtime = FlowDownChatClientKitModifierRuntime(environments: environments)
        let stream = AsyncStream<ChatResponseChunk> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, request, responseModifiers, runtime] in
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

                        let payloadData: Data
                        do {
                            payloadData = try Self.modifyResponsePayloadIfNeeded(
                                data,
                                modifiers: responseModifiers,
                                runtime: runtime
                            )
                        } catch {
                            await collectError(error)
                            continue
                        }

                        if let decodeError = errorExtractor.extractError(from: payloadData) {
                            await collectError(decodeError)
                            continue
                        }

                        do {
                            let payload = try chunkDecoder.decode(ResponsesStreamEvent.self, from: payloadData)

                            if let statusError = payload.asStatusError() {
                                await collectError(statusError)
                                finishReasonEmitted = true
                                continue
                            }

                            if let eventError = payload.asError() {
                                await collectError(eventError)
                                continue
                            }

                            if let chunk = Self.handle(
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

                let pendingCalls = toolCollector.finalizeRequests()
                for call in pendingCalls {
                    continuation.yield(.tool(call))
                }
                logger.info("responses streaming completed: received \(chunkCount) chunks, total content length: \(totalContentLength), tool calls: \(pendingCalls.count), ignored tool-like events: \(ignoredToolEvents.count)")
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }

    private static func modifyResponsePayloadIfNeeded(
        _ data: Data,
        modifiers: [String],
        runtime: FlowDownChatClientKitModifierRuntime
    ) throws -> Data {
        guard !modifiers.isEmpty else { return data }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FlowDownChatClientKitScriptError("Response modifiers require JSON object payloads.")
        }
        try runtime.applyResponseModifiers(modifiers, body: &object)
        return try JSONSerialization.data(withJSONObject: object, options: [])
    }
}

extension RemoteResponsesChatStreamProcessor {
    struct OutputItemMetadata {
        let role: String
        let outputIndex: Int?
    }

    static func handle(
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
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: delta
            )
        case .outputTextDone:
            let content = Self.resolvedFinalText(from: payload, streamedTextItemIDs: &streamedTextItemIDs)
            guard content != nil else { return nil }
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: content
            )
        case .reasoningTextDelta:
            guard let delta = payload.delta else { return nil }
            if let itemID = payload.itemID {
                streamedTextItemIDs.insert(itemID)
            }
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: delta
            )
        case .reasoningTextDone:
            let content = Self.resolvedFinalText(from: payload, streamedTextItemIDs: &streamedTextItemIDs)
            guard content != nil else { return nil }
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: content
            )
        case .refusalDelta:
            guard let delta = payload.delta else { return nil }
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                content: delta
            )
        case .refusalDone:
            return Self.makeChunk(
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
            return Self.makeChunk(
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
            return Self.makeChunk(
                payload: payload,
                outputMetadata: outputMetadata,
                reasoning: text
            )
        case .responseCompleted:
            guard !finishEmitted else { return nil }
            finishEmitted = true
            return Self.makeChunk(
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
            return Self.makeChunk(
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

    static func makeChunk(
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

    static func resolvedFinalText(
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
