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

private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
extension MLXChatClient {
    func streamingChatCompletionRequestExecute(
        body: ChatRequestBody,
        token: UUID
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        var userInput = try userInput(body: body)
        let generateParameters = generateParameters(body: body)
        let container = try await loadContainer(adjusting: &userInput)
        let toolSpecs = userInput.tools
        return try await container.perform(nonSendable: userInput) { context, lockedInput in
            let input = try await context.processor.prepare(input: lockedInput)

            let toolCallFormat = modelConfiguration.toolCallFormat
                ?? context.configuration.toolCallFormat
                ?? .json
            let streamInput = UnsafeSendableBox(input)
            let streamContext = UnsafeSendableBox(context)
            let streamParameters = generateParameters
            let streamToolSpecs = toolSpecs

            return AsyncThrowingStream { continuation in
                let workerTask = Task(priority: .userInitiated) {
                    defer { MLXChatClientQueue.shared.release(token: token) }

                    let input = streamInput.value
                    let context = streamContext.value

                    var toolStream = MLXToolStreamState(
                        format: toolCallFormat,
                        tools: streamToolSpecs,
                        toolChoice: body.toolChoice
                    )

                    var latestOutputLength = 0
                    var shouldRemoveLeadingWhitespace = true
                    var decoder = ChunkDecoder(context: context, input: input)

                    do {
                        let (tokenStream, generationTask) = try MLXLMCommon.generateTokensTask(
                            input: input,
                            parameters: streamParameters,
                            context: context
                        )
                        defer { generationTask.cancel() }

                        var generatedTokens: [Int] = []
                        generationLoop: for await generation in tokenStream {
                            if Task.isCancelled {
                                logger.debug("cancelling current inference due to Task.isCancelled")
                                generationTask.cancel()
                                break generationLoop
                            }

                            guard case let .token(token) = generation else {
                                continue
                            }

                            generatedTokens.append(token)
                            let decodeResult = decoder.decode(
                                tokens: generatedTokens,
                                latestOutputLength: &latestOutputLength,
                                shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
                            )

                            if let generatedChunk = decodeResult.chunk {
                                for chunk in toolStream.process(generatedChunk) {
                                    continuation.yield(chunk)
                                }
                            }

                            if decodeResult.shouldStop {
                                logger.info("reached an additional terminating token")
                                generationTask.cancel()
                                break generationLoop
                            }
                        }
                        await generationTask.value

                        let output = context.tokenizer.decode(tokenIds: generatedTokens)
                        if let finalChunk = decoder.makeChunk(
                            text: output,
                            previousLength: latestOutputLength,
                            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
                        ) {
                            for chunk in toolStream.process(finalChunk) {
                                continuation.yield(chunk)
                            }
                        }
                        if let finalChunk = decoder.finalize(
                            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
                        ) {
                            for chunk in toolStream.process(finalChunk) {
                                continuation.yield(chunk)
                            }
                        }

                        for chunk in toolStream.finish() {
                            continuation.yield(chunk)
                        }

                        logger.info("inference completed, total output length: \(output.count)")
                        continuation.finish()
                    } catch is CancellationError {
                        logger.debug("inference cancelled for token: \(token.uuidString)")
                        continuation.finish()
                    } catch {
                        logger.error("inference failed: \(error.localizedDescription)")
                        continuation.finish(throwing: error)
                    }
                }

                continuation.onTermination = { @Sendable reason in
                    guard case .cancelled = reason else { return }
                    logger.debug("stream cancelled before completion for token: \(token.uuidString)")
                    workerTask.cancel()
                    MLXChatClientQueue.shared.release(token: token)
                }
            }
        }.eraseToAnyAsyncSequence()
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
struct MLXToolStreamState {
    private let processor: ToolCallProcessor?
    private let inferredMistralToolName: String?
    private var pendingMistralOutputs: [ToolCallProcessor.Output] = []

    init(
        format: ToolCallFormat,
        tools: [[String: any Sendable]]?,
        toolChoice: ChatRequestBody.ToolChoice? = nil
    ) {
        processor = if let tools, !tools.isEmpty {
            ToolCallProcessor(format: format, tools: tools)
        } else {
            nil
        }
        let requiresTool = switch toolChoice {
        case .required, .function: true
        case .auto, nil: false
        }
        inferredMistralToolName = if format == .mistral,
                                    requiresTool,
                                    let tools,
                                    tools.count == 1,
                                    let function = tools[0]["function"] as? [String: any Sendable]
        {
            function["name"] as? String
        } else {
            nil
        }
    }

    mutating func process(_ generatedChunk: ChatCompletionChunk) -> [ChatResponseChunk] {
        generatedChunk.choices.flatMap { choice in
            var chunks: [ChatResponseChunk] = []
            if let reasoning = choice.delta.reasoningContent {
                chunks.append(.reasoning(reasoning))
            }
            guard let content = choice.delta.content else { return chunks }
            guard let processor else {
                chunks.append(.text(content))
                return chunks
            }

            let outputs = processor.processChunkOutputs(content)
            if inferredMistralToolName == nil {
                chunks.append(contentsOf: outputs.compactMap(responseChunk))
            } else {
                pendingMistralOutputs.append(contentsOf: outputs)
            }
            return chunks
        }
    }

    mutating func finish() -> [ChatResponseChunk] {
        guard let processor else { return [] }
        let eosOutputs = processor.processEOSOutputs()
        guard let toolName = inferredMistralToolName else {
            return eosOutputs.compactMap(responseChunk)
        }

        let outputs = pendingMistralOutputs + eosOutputs
        pendingMistralOutputs.removeAll(keepingCapacity: true)
        guard !outputs.contains(where: { output in
            if case .toolCall = output { true } else { false }
        }) else {
            return outputs.compactMap(responseChunk)
        }

        let text = outputs.reduce(into: "") { result, output in
            if case let .response(value) = output { result += value }
        }
        guard let arguments = bareToolArguments(from: text, toolName: toolName) else {
            return outputs.compactMap(responseChunk)
        }
        return [.tool(ToolRequest(name: toolName, args: arguments))]
    }

    private func bareToolArguments(from text: String, toolName: String) -> String? {
        guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let arguments: [String: Any]
        if object["name"] as? String == toolName,
           let nested = object["arguments"] as? [String: Any]
        {
            arguments = nested
        } else {
            arguments = object
        }
        guard let normalized = try? JSONSerialization.data(
            withJSONObject: arguments,
            options: [.sortedKeys]
        ) else { return nil }
        return String(data: normalized, encoding: .utf8)
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
func responseChunks(
    from generatedChunk: ChatCompletionChunk,
    toolProcessor: ToolCallProcessor?
) -> [ChatResponseChunk] {
    generatedChunk.choices.flatMap { choice in
        var chunks: [ChatResponseChunk] = []
        if let reasoning = choice.delta.reasoningContent {
            chunks.append(.reasoning(reasoning))
        }
        if let content = choice.delta.content {
            if let toolProcessor {
                chunks.append(contentsOf: toolProcessor.processChunkOutputs(content).compactMap(responseChunk))
            } else {
                chunks.append(.text(content))
            }
        }
        return chunks
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
func responseChunk(from output: ToolCallProcessor.Output) -> ChatResponseChunk? {
    switch output {
    case let .response(text):
        return .text(text)
    case let .toolCall(toolCall):
        return .tool(ToolRequest(
            id: toolCall.id,
            name: toolCall.function.name,
            args: toolCallArgsToJSON(toolCall.function.arguments)
        ))
    case let .rejectedToolCall(rejected):
        // A tool-call-shaped payload that could not become an executable call.
        // It is protocol residue, not assistant text, so it never reaches the UI.
        logger.warning("dropping rejected tool call: \(rejected.reason.rawValue)")
        return nil
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
struct ChunkDecodeResult {
    let chunk: ChatCompletionChunk?
    let shouldStop: Bool
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
struct ChunkDecoder {
    let context: ModelContext
    var reasoningEmitter: ReasoningEventEmitter?

    init(context: ModelContext, input: LMInput) {
        self.context = context
        guard let config = context.configuration.reasoningConfig else { return }

        let promptTokens = input.text.tokens.asArray(Int.self)
        let prompt = context.tokenizer.decode(tokenIds: promptTokens)
        let primedInside = ReasoningEventEmitter.promptEndsInsideReasoning(
            renderedPromptTail: prompt,
            config: config
        )
        reasoningEmitter = ReasoningEventEmitter(
            config: config,
            primedInside: primedInside
        )
    }

    mutating func decode(
        tokens: [Int],
        latestOutputLength: inout Int,
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChunkDecodeResult {
        var text = context.tokenizer.decode(tokenIds: tokens)
        let previousLength = latestOutputLength
        defer { latestOutputLength = text.count }

        while text.hasSuffix(MLXChatClient.decoderErrorSuffix) {
            text.removeLast(MLXChatClient.decoderErrorSuffix.count)
        }

        let chunk = makeChunk(
            text: text,
            previousLength: previousLength,
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

    mutating func makeChunk(
        text: String,
        previousLength: Int,
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChatCompletionChunk? {
        guard previousLength < text.count else { return nil }
        let chunkRange = previousLength ..< text.count
        let startIndex = text.index(text.startIndex, offsetBy: chunkRange.lowerBound)
        let endIndex = text.index(text.startIndex, offsetBy: chunkRange.upperBound)
        let chunkContent = String(text[startIndex ..< endIndex])

        let segments: [ReasoningEventEmitter.Segment]
        if var reasoningEmitter {
            segments = reasoningEmitter.process(chunkContent)
            self.reasoningEmitter = reasoningEmitter
        } else {
            segments = [.response(chunkContent)]
        }
        return makeChunk(
            segments: segments,
            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
        )
    }

    mutating func finalize(
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChatCompletionChunk? {
        guard var reasoningEmitter else { return nil }
        let segments = reasoningEmitter.finalize()
        self.reasoningEmitter = reasoningEmitter
        return makeChunk(
            segments: segments,
            shouldRemoveLeadingWhitespace: &shouldRemoveLeadingWhitespace
        )
    }

    private func makeChunk(
        segments: [ReasoningEventEmitter.Segment],
        shouldRemoveLeadingWhitespace: inout Bool
    ) -> ChatCompletionChunk? {
        let choices = segments.compactMap { segment -> ChatCompletionChunk.Choice? in
            var text: String
            let isReasoning: Bool
            switch segment {
            case let .reasoning(value):
                text = value
                isReasoning = true
            case let .response(value):
                text = value
                isReasoning = false
            }

            if shouldRemoveLeadingWhitespace {
                text = text.trimmingCharactersFromStart(in: .whitespacesAndNewlines)
                shouldRemoveLeadingWhitespace = text.isEmpty
            }
            guard !text.isEmpty else { return nil }

            let delta = if isReasoning {
                ChatCompletionChunk.Choice.Delta(reasoningContent: text)
            } else {
                ChatCompletionChunk.Choice.Delta(content: text)
            }
            return .init(delta: delta)
        }
        return choices.isEmpty ? nil : .init(choices: choices)
    }
}

@available(iOS 17.0, macOS 14.0, macCatalyst 17.0, *)
private func toolCallArgsToJSON(_ arguments: [String: JSONValue]) -> String {
    let anyObject = arguments.mapValues { $0.anyValue }
    guard let data = try? JSONSerialization.data(withJSONObject: anyObject, options: [.sortedKeys]),
          let json = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }
    return json
}
