//
//  ReasoningContentParser.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct ReasoningContentParser: Sendable {
    let startToken: String
    let endToken: String

    init(startToken: String = REASONING_START_TOKEN, endToken: String = REASONING_END_TOKEN) {
        self.startToken = startToken
        self.endToken = endToken
    }

    func extractingReasoningContent(from choice: ChoiceMessage) -> ChoiceMessage {
        guard choice.reasoning?.isEmpty != false,
              choice.reasoningContent?.isEmpty != false,
              let content = choice.content,
              let startRange = content.range(of: startToken),
              let endRange = content.range(of: endToken, range: startRange.upperBound ..< content.endIndex)
        else {
            return choice
        }

        let reasoningRange = startRange.upperBound ..< endRange.lowerBound
        let leading = content[..<startRange.lowerBound]
        let trailing = content[endRange.upperBound...]

        let reasoningContent = content[reasoningRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainingContent = String(
            (leading + trailing)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var newChoice = choice
        newChoice.content = remainingContent
        newChoice.reasoningContent = reasoningContent
        return newChoice
    }
}

struct ReasoningStreamReducer: Sendable {
    private let parser: ReasoningContentParser
    private var isInsideReasoningContent = false
    private var contentBuffer = ""

    init(parser: ReasoningContentParser) {
        self.parser = parser
    }

    mutating func process(
        contentSegments: [String],
        into chunk: inout ChatCompletionChunk
    ) {
        guard !contentSegments.isEmpty else { return }
        reduceReasoningContent(
            parser: parser,
            content: contentSegments,
            reasoningContent: [],
            isInsideReasoning: &isInsideReasoningContent,
            buffer: &contentBuffer,
            response: &chunk
        )
    }

    mutating func flushRemaining() -> [ChatServiceStreamObject] {
        guard !contentBuffer.isEmpty else { return [] }

        var emittedObjects: [ChatServiceStreamObject] = []

        if isInsideReasoningContent {
            emittedObjects.append(.chatCompletionChunk(chunk: .init(
                choices: [.init(delta: .init(reasoningContent: contentBuffer))]
            )))
            contentBuffer = ""
            isInsideReasoningContent = false
            return emittedObjects
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
                response: &response
            )

            if !response.choices.isEmpty {
                emittedObjects.append(.chatCompletionChunk(chunk: response))
                continue
            }

            if pendingBuffer.contains(parser.startToken) || pendingBuffer.contains(parser.endToken) {
                let sanitized = pendingBuffer
                    .replacingOccurrences(of: parser.startToken, with: "")
                    .replacingOccurrences(of: parser.endToken, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !sanitized.isEmpty {
                    emittedObjects.append(.chatCompletionChunk(chunk: .init(
                        choices: [.init(delta: .init(reasoningContent: sanitized))]
                    )))
                }
            } else {
                emittedObjects.append(.chatCompletionChunk(chunk: .init(
                    choices: [.init(delta: .init(content: pendingBuffer))]
                )))
            }
            contentBuffer = ""
        }

        return emittedObjects
    }
}

private func reduceReasoningContent(
    parser: ReasoningContentParser,
    content: [String],
    reasoningContent: [String],
    isInsideReasoning: inout Bool,
    buffer: inout String,
    response: inout ChatCompletionChunk
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
                reasoningContent: bufferContent
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
                refusal: firstChoice.delta.refusal,
                role: firstChoice.delta.role,
                toolCalls: firstChoice.delta.toolCalls
            )
            updatedChoices[0] = .init(
                delta: updatedDelta,
                finishReason: firstChoice.finishReason,
                index: firstChoice.index
            )
            response.choices = updatedChoices
        }
    }
}
