//
//  CompletionToolCollector.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

class CompletionToolCollector {
    var functionName = ""
    var functionArguments = ""
    var toolCallID: String?
    var extraFields: [String: AnyCodingValue] = [:]
    var currentId: Int?
    var pendingRequests: [ToolRequest] = []

    func submit(delta: ChatCompletionChunk.Choice.Delta.ToolCall) {
        let deltaExtraFields = delta.extraFields ?? [:]
        guard delta.function != nil || !deltaExtraFields.isEmpty else { return }

        if currentId != delta.index {
            finalizeCurrentDeltaContent()
        }
        currentId = delta.index
        if let id = delta.id, !id.isEmpty {
            toolCallID = id
        }
        // Provider fields arrive whole on one delta; a later delta that
        // repeats a key replaces it rather than concatenating.
        extraFields.merge(deltaExtraFields) { _, new in new }

        if let name = delta.function?.name, !name.isEmpty {
            functionName.append(name)
        }
        if let arguments = delta.function?.arguments {
            functionArguments.append(arguments)
        }
    }

    func finalizeCurrentDeltaContent() {
        guard !functionName.isEmpty || !functionArguments.isEmpty else {
            extraFields = [:]
            return
        }
        let call = ToolRequest(
            id: toolCallID,
            name: functionName,
            args: functionArguments,
            extraFields: extraFields
        )
        logger.debug("tool call finalized: \(call.name) with args: \(call.args)")
        pendingRequests.append(call)
        functionName = ""
        functionArguments = ""
        toolCallID = nil
        extraFields = [:]
    }

    func reset() {
        functionName = ""
        functionArguments = ""
        toolCallID = nil
        extraFields = [:]
        currentId = nil
        pendingRequests = []
    }
}
