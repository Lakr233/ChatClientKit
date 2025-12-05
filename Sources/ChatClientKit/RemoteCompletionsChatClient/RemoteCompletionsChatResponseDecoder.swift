//
//  RemoteCompletionsChatResponseDecoder.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

struct RemoteCompletionsChatResponseDecoder {
    private let decoder: JSONDecoding
    private let reasoningParser: ReasoningContentParser

    init(
        decoder: JSONDecoding = JSONDecoderWrapper(),
        reasoningParser: ReasoningContentParser = .init(),
    ) {
        self.decoder = decoder
        self.reasoningParser = reasoningParser
    }

    func decodeResponse(from data: Data) throws -> ChatResponseBody {
        var response = try decoder.decode(ChatResponseBody.self, from: data)
        response.choices = response.choices.map { choice in
            var mutableChoice = choice
            mutableChoice.message = reasoningParser.extractingReasoningContent(from: choice.message)
            mutableChoice.message.reasoningDetails = AssistantTurnContent.mergeReasoningDetails(
                existing: [],
                incoming: mutableChoice.message.reasoningDetails,
                fallback: mutableChoice.message.reasoning ?? mutableChoice.message.reasoningContent,
            )
            return mutableChoice
        }
        return response
    }
}
