//
//  PostProcessor.swift
//  ChatClientKit
//
//  Wraps a ScriptRunner.invoke for the `post_process` stage. Called
//  once per SSE chunk that the StreamProcessor consumes.
//
//  Two modes:
//   - inherit=true:  Swift first parses the chunk into
//                    {reasoning, content, tool_calls}; JS sees that obj
//                    and returns a (possibly modified) PostProcessOutput.
//   - inherit=false: JS sees the raw `line` string (already stripped of
//                    `data:` prefix by ServerSentEvent.parse) and is
//                    responsible for parsing it itself.
//

import Foundation

struct PostProcessor {
    let runner: ScriptRunner
    let stage: ChatClientKitScriptConfig.Stage

    /// inherit=true path. Feeds parsed payload to JS.
    func processParsed(_ parsed: PostProcessOutput) throws -> PostProcessOutput {
        guard stage.inherit else {
            // Caller used the wrong path; defensively forward unchanged.
            return parsed
        }
        let bindings: [String: Any] = try [
            "parsed": toJSAny(parsed),
        ]
        return try runner.invoke(
            script: stage.script,
            bindings: bindings
        )
    }

    /// inherit=false path. Feeds raw SSE-data line to JS.
    func processRawLine(_ line: String) throws -> PostProcessOutput {
        let bindings: [String: Any] = [
            "line": line,
        ]
        return try runner.invoke(
            script: stage.script,
            bindings: bindings
        )
    }

    /// Convenience: choose path based on stage.inherit.
    func process(parsed: PostProcessOutput, rawLine: String) throws -> PostProcessOutput {
        if stage.inherit {
            try processParsed(parsed)
        } else {
            try processRawLine(rawLine)
        }
    }

    private func toJSAny<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}
