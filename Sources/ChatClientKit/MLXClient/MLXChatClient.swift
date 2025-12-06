//
//  Created by ktiays on 2025/2/18.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import CoreImage
import Foundation
@preconcurrency import MLXLMCommon

public class MLXChatClient: ChatService, @unchecked Sendable {
    let modelConfiguration: ModelConfiguration
    let emptyImage: CIImage = MLXImageUtilities.placeholderImage(
        size: .init(width: 64, height: 64),
    )
    let coordinator: MLXModelCoordinating
    let preferredKind: MLXModelKind

    // Hex UTF-8 bytes EF BF BD
    static let decoderErrorSuffix = String(data: Data([0xEF, 0xBF, 0xBD]), encoding: .utf8)!

    public let errorCollector = ChatServiceErrorCollector()

    public init(
        url: URL,
        preferredKind: MLXModelKind = .llm,
        coordinator: MLXModelCoordinating = MLXModelCoordinator.shared,
    ) {
        modelConfiguration = .init(directory: url)
        self.preferredKind = preferredKind
        self.coordinator = coordinator
    }

    public func chatCompletionRequest(body: ChatRequestBody) async throws -> ChatResponseBody {
        logger.info("starting non-streaming chat completion request with \(body.messages.count) messages")
        let startTime = Date()
        let resolvedBody = resolve(body: body, stream: false)
        let aggregated: String = try await streamingChatCompletionRequest(body: resolvedBody)
            .compactMap { chunk -> ChatCompletionChunk? in
                if case let .chatCompletionChunk(chunk) = chunk { return chunk }
                return nil
            }
            .compactMap { $0.choices.first?.delta.content }
            .reduce(into: "") { partial, segment in
                var updated = partial + segment
                for terminator in ChatClientConstants.additionalTerminatingTokens {
                    while updated.hasSuffix(terminator) {
                        updated.removeLast(terminator.count)
                    }
                }
                partial = updated
            }
        let duration = Date().timeIntervalSince(startTime)
        logger.info("completed non-streaming request in \(String(format: "%.2f", duration))s, content length: \(aggregated.count)")
        return .text(aggregated)
    }

    public func streamingChatCompletionRequest(
        body: ChatRequestBody,
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        let resolvedBody = resolve(body: body, stream: true)
        logger.info("starting streaming chat completion request with \(resolvedBody.messages.count) messages, max tokens: \(resolvedBody.maxCompletionTokens ?? 4096)")
        let token = MLXChatClientQueue.shared.acquire()
        do {
            return try await streamingChatCompletionRequestExecute(body: resolvedBody, token: token)
        } catch {
            logger.error("streaming request failed: \(error.localizedDescription)")
            MLXChatClientQueue.shared.release(token: token)
            throw error
        }
    }

    func chatCompletionRequest(
        _ request: some ChatRequestConvertible,
    ) async throws -> ChatResponseBody {
        try await chatCompletionRequest(body: request.asChatRequestBody())
    }

    func streamingChatCompletionRequest(
        _ request: some ChatRequestConvertible,
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(body: request.asChatRequestBody())
    }

    /// Executes a local MLX completion using the Swift request DSL.
    func chatCompletion(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> ChatResponseBody {
        try await chatCompletionRequest(ChatRequest(builder))
    }

    /// Streams a local MLX completion using the Swift request DSL.
    func streamingChatCompletion(
        @ChatRequestBuilder _ builder: @Sendable () -> [ChatRequest.BuildComponent],
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        try await streamingChatCompletionRequest(ChatRequest(builder))
    }
}
