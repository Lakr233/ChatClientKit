//
//  RequestSanitizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

struct RequestSanitizer: RequestSanitizing {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody {
        let sanitizedMessages = SanitizationRule.applyAll(on: body.messages)
        let sanitizedTools = ToolStrictNormalizer.normalize(body.tools)

        var sanitizedBody = ChatRequestBody(
            messages: sanitizedMessages,
            maxCompletionTokens: body.maxCompletionTokens,
            stream: body.stream,
            temperature: body.temperature,
            tools: sanitizedTools,
        )
        sanitizedBody.model = body.model
        return sanitizedBody
    }
}
