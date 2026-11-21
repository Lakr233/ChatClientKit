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

        if startsNewCall(delta) {
            finalizeCurrentDeltaContent()
        }
        currentId = delta.index
        // The first id names the call; a fragment that carries another one
        // (see `startsNewCall`) does not rename it.
        if let id = delta.id, !id.isEmpty, (toolCallID ?? "").isEmpty {
            toolCallID = id
        }
        // Provider fields arrive whole on one delta; a later delta that
        // repeats a key replaces it rather than concatenating.
        extraFields.merge(deltaExtraFields) { _, new in new }

        if let name = delta.function?.name, !name.isEmpty {
            mergeName(name)
        }
        if let arguments = delta.function?.arguments {
            functionArguments.append(arguments)
        }
    }

    /// Decides whether a delta begins another call or continues the
    /// current one.
    ///
    /// - A different `index` always begins another call (OpenAI numbers
    ///   parallel calls 0, 1, … and sends id and name only on the first
    ///   fragment of each).
    /// - Within one index, a non-empty id different from the current call's
    ///   begins another call. Gemini's OpenAI-compatible endpoint sends each
    ///   parallel call whole in its own delta without `index`, and some
    ///   servers send index 0 for all of them. Exception: a delta with no
    ///   name while the current arguments are not yet complete JSON is a
    ///   fragment of the current call, whatever id it carries.
    /// - The same id, or an empty or missing id, never begins another call by
    ///   itself.
    /// - Without a usable id, a name arriving for a call that already has one
    ///   begins another call once the current arguments are complete JSON.
    ///   Before that it continues the call when it repeats the current name
    ///   (or grows it, as llama.cpp may send) or when no arguments have
    ///   arrived yet. Servers that repeat the name on every fragment
    ///   therefore keep one call.
    private func startsNewCall(_ delta: ChatCompletionChunk.Choice.Delta.ToolCall) -> Bool {
        if currentId != delta.index { return true }
        guard !functionName.isEmpty || !functionArguments.isEmpty else { return false }

        let deltaID = delta.id ?? ""
        let deltaName = delta.function?.name ?? ""
        let currentID = toolCallID ?? ""

        if !deltaID.isEmpty, !currentID.isEmpty {
            guard deltaID != currentID else { return false }
            if deltaName.isEmpty, !Self.isCompleteJSON(functionArguments) { return false }
            return true
        }
        guard !deltaName.isEmpty, !functionName.isEmpty else { return false }
        if Self.isCompleteJSON(functionArguments) { return true }
        // Arguments still open: the same (or grown) name is repeated, and a
        // name before any arguments is a fragment of the current name.
        if isSameName(deltaName) || functionArguments.isEmpty { return false }
        return true
    }

    /// A name equal to the current one, or the current one grown longer.
    private func isSameName(_ name: String) -> Bool {
        name == functionName || name.hasPrefix(functionName)
    }

    /// A repeated name changes nothing and a grown name replaces the shorter
    /// one; anything else is a fragment and is appended.
    private func mergeName(_ name: String) {
        if functionName.isEmpty || name.hasPrefix(functionName) {
            functionName = name
        } else {
            functionName.append(name)
        }
    }

    static func isCompleteJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
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
