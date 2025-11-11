//
//  ToolCallCollector.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

final class ToolCallCollector {
    private var functionName = ""
    private var functionArguments = ""
    private var currentId: Int?
    private(set) var pendingRequests: [ToolCallRequest] = []

    func submit(delta: ChatCompletionChunk.Choice.Delta.ToolCall) {
        guard let function = delta.function else { return }

        if currentId != delta.index {
            finalizeCurrentDeltaContent()
        }
        currentId = delta.index

        if let name = function.name, !name.isEmpty {
            functionName.append(name)
        }
        if let arguments = function.arguments {
            functionArguments.append(arguments)
        }
    }

    func finalizeCurrentDeltaContent() {
        guard !functionName.isEmpty || !functionArguments.isEmpty else {
            return
        }
        let call = ToolCallRequest(name: functionName, args: functionArguments)
        logger.debugFile("tool call finalized: \(call.name) with args: \(call.args)")
        pendingRequests.append(call)
        functionName = ""
        functionArguments = ""
    }

    func reset() {
        functionName = ""
        functionArguments = ""
        currentId = nil
        pendingRequests = []
    }
}
