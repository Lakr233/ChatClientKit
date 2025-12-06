//
//  CompletionReasoningContentCollector.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct CompletionReasoningContentCollector: Sendable {
    let startToken: String
    let endToken: String

    init(startToken: String = REASONING_START_TOKEN, endToken: String = REASONING_END_TOKEN) {
        self.startToken = startToken
        self.endToken = endToken
    }

    func extractingReasoningContent(
        from delta: ChatCompletionChunk.Choice.Delta,
    ) -> ChatCompletionChunk.Choice.Delta {
        guard delta.reasoning?.isEmpty != false,
              delta.reasoningContent?.isEmpty != false,
              let content = delta.content,
              let startRange = content.range(of: startToken),
              let endRange = content.range(of: endToken, range: startRange.upperBound ..< content.endIndex)
        else { return delta }

        let reasoningRange = startRange.upperBound ..< endRange.lowerBound
        let leading = content[..<startRange.lowerBound]
        let trailing = content[endRange.upperBound...]

        let reasoningContent = content[reasoningRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingContent = String(
            (leading + trailing)
                .trimmingCharacters(in: .whitespacesAndNewlines),
        )

        return ChatCompletionChunk.Choice.Delta(
            content: remainingContent,
            reasoning: delta.reasoning,
            reasoningContent: reasoningContent,
            role: delta.role,
            toolCalls: delta.toolCalls,
            images: delta.images,
        )
    }
}

struct ReasoningStreamReducer: Sendable {
    let parser: CompletionReasoningContentCollector
    var isInsideReasoningContent = false
    var contentBuffer = ""

    init(parser: CompletionReasoningContentCollector) {
        self.parser = parser
    }

    mutating func process(
        contentSegments: [String],
        into chunk: inout ChatCompletionChunk,
    ) {
        guard !contentSegments.isEmpty else { return }
        reduceReasoningContent(
            parser: parser,
            content: contentSegments,
            reasoningContent: [],
            isInsideReasoning: &isInsideReasoningContent,
            buffer: &contentBuffer,
            response: &chunk,
        )
    }

    mutating func flushRemaining() -> [ChatCompletionChunk] {
        guard !contentBuffer.isEmpty else { return [] }

        var emittedChunks: [ChatCompletionChunk] = []

        if isInsideReasoningContent {
            emittedChunks.append(.init(
                choices: [.init(delta: .init(reasoningContent: contentBuffer))],
            ))
            contentBuffer = ""
            isInsideReasoningContent = false
            return emittedChunks
        }

        while !contentBuffer.isEmpty {
            let pendingBuffer = contentBuffer
            var response = ChatCompletionChunk(choices: [])
            reduceReasoningContent(
                parser: parser,
                content: [],
                reasoningContent: [],
                isInsideReasoning: &isInsideReasoningContent,
                buffer: &contentBuffer,
                response: &response,
            )

            if !response.choices.isEmpty {
                emittedChunks.append(response)
                continue
            }

            if pendingBuffer.contains(parser.startToken) || pendingBuffer.contains(parser.endToken) {
                let sanitized = pendingBuffer
                    .replacingOccurrences(of: parser.startToken, with: "")
                    .replacingOccurrences(of: parser.endToken, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sanitized.isEmpty {
                    emittedChunks.append(.init(
                        choices: [.init(delta: .init(reasoningContent: sanitized))],
                    ))
                }
            } else {
                emittedChunks.append(.init(
                    choices: [.init(delta: .init(content: pendingBuffer))],
                ))
            }
            contentBuffer = ""
        }

        return emittedChunks
    }
}

func reduceReasoningContent(
    parser: CompletionReasoningContentCollector,
    content: [String],
    reasoningContent: [String],
    isInsideReasoning: inout Bool,
    buffer: inout String,
    response: inout ChatCompletionChunk,
) {
    let previousBuffer = buffer
    var hasProcessedReasoningToken = isInsideReasoning
    let bufferContent = buffer + content.joined()
    assert(reasoningContent.isEmpty)
    buffer = ""

    if !isInsideReasoning {
        if let range = bufferContent.range(of: parser.startToken) {
            hasProcessedReasoningToken = true
            let beforeReasoning = String(bufferContent[..<range.lowerBound])
                .trimmingCharactersFromEnd(in: .whitespacesAndNewlines)
            let afterReasoningBegin = String(bufferContent[range.upperBound...])
                .trimmingCharactersFromStart(in: .whitespacesAndNewlines)

            if let endRange = afterReasoningBegin.range(of: parser.endToken) {
                let reasoningText = String(afterReasoningBegin[..<endRange.lowerBound])
                    .trimmingCharactersFromEnd(in: .whitespacesAndNewlines)
                let remainingText = String(afterReasoningBegin[endRange.upperBound...])
                    .trimmingCharactersFromStart(in: .whitespacesAndNewlines)

                if !beforeReasoning.isEmpty {
                    response = .init(choices: [.init(delta: .init(content: beforeReasoning))])
                    if !reasoningText.isEmpty || !remainingText.isEmpty {
                        buffer = "\(parser.startToken)\(reasoningText)\(parser.endToken)\(remainingText)"
                    }
                } else if !reasoningText.isEmpty {
                    response = .init(choices: [.init(delta: .init(reasoningContent: reasoningText))])
                    if !remainingText.isEmpty {
                        buffer = remainingText
                    }
                } else if !remainingText.isEmpty {
                    response = .init(choices: [.init(delta: .init(content: remainingText))])
                } else {
                    response = .init(choices: [])
                }
            } else {
                isInsideReasoning = true
                if !beforeReasoning.isEmpty {
                    response = .init(choices: [.init(delta: .init(content: beforeReasoning))])
                    if !afterReasoningBegin.isEmpty {
                        buffer = afterReasoningBegin
                    }
                } else if !afterReasoningBegin.isEmpty {
                    response = .init(choices: [.init(delta: .init(reasoningContent: afterReasoningBegin))])
                } else {
                    response = .init(choices: [])
                }
            }
        }
    } else {
        hasProcessedReasoningToken = true
        if let range = bufferContent.range(of: parser.endToken) {
            isInsideReasoning = false

            let reasoningText = String(bufferContent[..<range.lowerBound])
                .trimmingCharactersFromEnd(in: .whitespacesAndNewlines)
            let remainingText = String(bufferContent[range.upperBound...])
                .trimmingCharactersFromStart(in: .whitespacesAndNewlines)

            if !reasoningText.isEmpty {
                response = .init(choices: [.init(delta: .init(reasoningContent: reasoningText))])
            } else {
                response = .init(choices: [])
            }
            if !remainingText.isEmpty {
                buffer = remainingText
            }
        } else {
            response = .init(choices: [.init(delta: .init(
                reasoningContent: bufferContent,
            ))])
        }
    }

    if !hasProcessedReasoningToken,
       !previousBuffer.isEmpty,
       !previousBuffer.contains(parser.startToken),
       !previousBuffer.contains(parser.endToken)
    {
        if response.choices.isEmpty {
            response = .init(choices: [.init(delta: .init(content: previousBuffer))])
        } else {
            var updatedChoices = response.choices
            let firstChoice = updatedChoices[0]
            let mergedContent = previousBuffer + (firstChoice.delta.content ?? "")
            let updatedDelta = ChatCompletionChunk.Choice.Delta(
                content: mergedContent,
                reasoning: firstChoice.delta.reasoning,
                reasoningContent: firstChoice.delta.reasoningContent,
                role: firstChoice.delta.role,
                toolCalls: firstChoice.delta.toolCalls,
                images: firstChoice.delta.images,
            )
            updatedChoices[0] = .init(
                delta: updatedDelta,
                finishReason: firstChoice.finishReason,
                index: firstChoice.index,
            )
            response = .init(choices: updatedChoices)
        }
    }
}
