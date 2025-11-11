//
//  MLXChatClient+Streaming.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import CoreImage
import Foundation
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon
@preconcurrency import MLXVLM
import Tokenizers

extension MLXChatClient {
    func streamingChatCompletionRequestExecute(
        body: ChatRequestBody,
        token: UUID
    ) async throws -> AnyAsyncSequence<ChatServiceStreamObject> {
        var userInput = userInput(body: body)
        let generateParameters = generateParameters(body: body)
        let container = try await loadContainer(adjusting: &userInput)
        let lockedInput = userInput
        return try await container.perform { context in
            let input = try await context.processor.prepare(input: lockedInput)

            return AsyncThrowingStream { continuation in
                let workerTask = Task.detached(priority: .userInitiated) {
                    defer { MLXChatClientQueue.shared.release(token: token) }

                    var latestOutputLength = 0
                    var isReasoning = false
                    var shouldRemoveLeadingWhitespace = true
                    var decoder = ChunkDecoder(context: context)
                    var regularContentOutputLength = 0

                    do {
                        let result = try MLXLMCommon.generate(
                            input: input,
                            parameters: generateParameters,
                            context: context
                        ) { tokens in
                            let decodeResult = decoder.decode(
                                tokens: tokens,
                                latestOutputLength: &latestOutputLength,
                                isReasoning: &isReasoning,
                                shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
                            )

                            if let generatedChunk = decodeResult.chunk {
                                if !isReasoning {
                                    regularContentOutputLength += generatedChunk.choices
                                        .compactMap(\.delta.content?.count)
                                        .reduce(0, +)
                                }
                                continuation.yield(ChatServiceStreamObject.chatCompletionChunk(chunk: generatedChunk))
                            }

                            if decodeResult.shouldStop || regularContentOutputLength >= body.maxCompletionTokens ?? 4096 {
                                logger.infoFile("reached max completion tokens: \(regularContentOutputLength)")
                                return .stop
                            }

                            if Task.isCancelled {
                                logger.debugFile("cancelling current inference due to Task.isCancelled")
                                return .stop
                            }

                            return .more
                        }

                        let output = result.output
                        if let finalChunk = decoder.makeChunk(
                            text: output,
                            previousLength: latestOutputLength,
                            isReasoning: isReasoning,
                            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
                        ) {
                            continuation.yield(.chatCompletionChunk(chunk: finalChunk))
                        }

                        logger.infoFile("inference completed, total output length: \(output.count), regular content: \(regularContentOutputLength)")
                        continuation.finish()
                    } catch is CancellationError {
                        logger.debugFile("inference cancelled for token: \(token.uuidString)")
                        continuation.finish()
                    } catch {
                        logger.errorFile("inference failed: \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable reason in
                    guard case .cancelled = reason else { return }
                    logger.debugFile("stream cancelled before completion for token: \(token.uuidString)")
                    workerTask.cancel()
                    MLXChatClientQueue.shared.release(token: token)
                }
            }
        }.eraseToAnyAsyncSequence()
    }
}

private struct ChunkDecodeResult {
    let chunk: ChatCompletionChunk?
    let shouldStop: Bool
}

private struct ChunkDecoder {
    let context: ModelContext

    mutating func decode(
        tokens: [Int],
        latestOutputLength: inout Int,
        isReasoning: inout Bool,
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChunkDecodeResult {
        var text = context.tokenizer.decode(tokens: tokens)
        let previousLength = latestOutputLength
        defer { latestOutputLength = text.count }

        while text.hasSuffix(MLXChatClient.decoderErrorSuffix) {
            text.removeLast(MLXChatClient.decoderErrorSuffix.count)
        }

        if toggleReasoningIfNeeded(lastToken: tokens.last, isReasoning: &isReasoning) {
            shouldRemoveLeadingWhitespace = true
            return .init(chunk: nil, shouldStop: false)
        }

        let chunk = makeChunk(
            text: text,
            previousLength: previousLength,
            isReasoning: isReasoning,
            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
        )

        var mutableText = text
        var shouldStop = false
        for terminator in ChatClientConstants.additionalTerminatingTokens {
            var terminated = false
            while mutableText.hasSuffix(terminator) {
                mutableText.removeLast(terminator.count)
                terminated = true
            }
            if terminated {
                shouldStop = true
            }
        }

        return .init(chunk: chunk, shouldStop: shouldStop)
    }

    private func toggleReasoningIfNeeded(lastToken: Int?, isReasoning: inout Bool) -> Bool {
        guard let lastToken else { return false }
        let text = context.tokenizer.decode(tokens: [lastToken]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !isReasoning, text == REASONING_START_TOKEN {
            logger.infoFile("starting reasoning with token \(text)")
            isReasoning = true
            return true
        }
        if isReasoning, text == REASONING_END_TOKEN {
            logger.infoFile("end reasoning with token \(text)")
            isReasoning = false
            return true
        }
        return false
    }

    func makeChunk(
        text: String,
        previousLength: Int,
        isReasoning: Bool,
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChatCompletionChunk? {
        guard previousLength < text.count else { return nil }
        let chunkRange = previousLength ..< text.count
        let startIndex = text.index(text.startIndex, offsetBy: chunkRange.lowerBound)
        let endIndex = text.index(text.startIndex, offsetBy: chunkRange.upperBound)
        var chunkContent = String(text[startIndex ..< endIndex])

        if shouldRemoveLeadingWhitespace {
            chunkContent = chunkContent.trimmingCharactersFromStart(in: .whitespacesAndNewlines)
            shouldRemoveLeadingWhitespace = chunkContent.isEmpty
        }

        guard !chunkContent.isEmpty else { return nil }

        let delta = if isReasoning {
            ChatCompletionChunk.Choice.Delta(reasoningContent: chunkContent)
        } else {
            ChatCompletionChunk.Choice.Delta(content: chunkContent)
        }
        let choice: ChatCompletionChunk.Choice = .init(delta: delta)
        return .init(choices: [choice])
    }
}
