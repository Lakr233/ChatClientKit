//
//  RemoteChatStreamProcessor.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation
import ServerEvent

struct RemoteChatStreamProcessor {
    private let eventSourceFactory: EventSourceProducing
    private let chunkDecoder: JSONDecoding
    private let errorExtractor: RemoteChatErrorExtractor
    private let reasoningParser: ReasoningContentParser

    init(
        eventSourceFactory: EventSourceProducing = DefaultEventSourceFactory(),
        chunkDecoder: JSONDecoding = JSONDecoderWrapper(),
        errorExtractor: RemoteChatErrorExtractor = RemoteChatErrorExtractor(),
        reasoningParser: ReasoningContentParser = .init()
    ) {
        self.eventSourceFactory = eventSourceFactory
        self.chunkDecoder = chunkDecoder
        self.errorExtractor = errorExtractor
        self.reasoningParser = reasoningParser
    }

    func stream(
        request: URLRequest,
        collectError: @Sendable @escaping (Swift.Error) async -> Void
    ) -> AnyAsyncSequence<ChatServiceStreamObject> {
        let eventSourceFactory = eventSourceFactory
        let chunkDecoder = chunkDecoder
        let errorExtractor = errorExtractor
        let reasoningParser = reasoningParser

        let stream = AsyncStream<ChatServiceStreamObject> { continuation in
            Task.detached(priority: .userInitiated) { [collectError, eventSourceFactory, chunkDecoder, errorExtractor, reasoningParser, request] in
                var canDecodeReasoningContent = true
                var reducer = ReasoningStreamReducer(parser: reasoningParser)
                let toolCallCollector = ToolCallCollector()
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
                            continuation.yield(.chatCompletionChunk(chunk: response))
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
                    continuation.yield(leftover)
                }

                toolCallCollector.finalizeCurrentDeltaContent()
                for call in toolCallCollector.pendingRequests {
                    continuation.yield(.tool(call: call))
                }
                logger.info("streaming completed: received \(chunkCount) chunks, total content length: \(totalContentLength), tool calls: \(toolCallCollector.pendingRequests.count)")
                continuation.finish()
            }
        }
        return stream.eraseToAnyAsyncSequence()
    }
}
