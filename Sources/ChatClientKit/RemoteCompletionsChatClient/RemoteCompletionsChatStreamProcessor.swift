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

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteCompletionsChatErrorExtractor = RemoteCompletionsChatErrorExtractor(),
        reasoningParser: CompletionReasoningDecoder = .init(),
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
        self.reasoningParser = reasoningParser
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void,
    ) -> AnyAsyncSequence<ChatResponseChunk> {
        let eventSourceFactory = eventSourceFactory
        let chunkDecoder = chunkDecoder
        let errorExtractor = errorExtractor
        let reasoningParser = reasoningParser

        let stream = AsyncStream<ChatResponseChunk> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, reasoningParser, request] in
                var canDecodeReasoningContent = true
                var reducer = ReasoningStreamReducer(parser: reasoningParser)
                let toolCallCollector = CompletionToolCollector()
                var chunkCount = 0
                var totalContentLength = 0

                let streamTask = eventSourceFactory.makeDataTask(for: request)

                for await event in streamTask.events() {
                    switch event {
                    case .open:
                        logger.info("connection was opened.")
                    case let .error(error):
                        logger.error("received an error: \(error)")
                        await collectError(error)
                    case let .event(event):
                        guard let data = event.data?.data(using: .utf8) else {
                            continue
                        }
                        if let text = String(data: data, encoding: .utf8),
                           text.lowercased() == "[done]".lowercased()
                        {
                            logger.debug("received done from upstream")
                            continue
                        }

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
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }
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
