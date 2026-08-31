//
//  ScriptRuntime.swift
//  ChatClientKit
//
//  Bundles a ScriptRunner with its Pre/Post processors for a single
//  streamingChat request lifetime. One runtime per request.
//

import Foundation

/// Built once at the start of a streamingChat call. Discarded when the
/// stream ends. Never reused across requests.
struct ScriptRuntime {
    let runner: ScriptRunner
    let preProcessor: PreProcessor?
    let postProcessor: PostProcessor?

    /// Build from a request body + a (possibly partial) scripting handle.
    /// Errors only if Codable serialization of body/manifest fails, which
    /// is logged and surfaced to the caller.
    static func make(
        body: ChatRequestBody,
        handle: ChatScriptingHandle
    ) throws -> ScriptRuntime {
        let session = try ChatSessionSnapshot.make(from: body)
        let initial = handle.readContext()

        let bridge = ScriptBridge(onWriteContext: handle.writeContext)
        let runner = try ScriptRunner(
            initialContextJSON: initial,
            manifest: handle.manifest,
            session: session,
            bridge: bridge
        )

        let pre = handle.config.preProcess.map {
            PreProcessor(runner: runner, stage: $0)
        }
        let post = handle.config.postProcess.map {
            PostProcessor(runner: runner, stage: $0)
        }
        return ScriptRuntime(runner: runner, preProcessor: pre, postProcessor: post)
    }
}
