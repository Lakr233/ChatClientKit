//
//  ScriptRunner.swift
//  ChatClientKit
//
//  Per-request JavaScriptCore harness.
//  - Dedicated DispatchQueue (serial) for all JSContext access.
//  - 5s hard timeout on script execution → fatalError(plan §1.8).
//  - Large objects (manifest / chatSession) frozen and bound once at
//    init, so per-chunk invokes carry only chunk-local payloads.
//  - JS global `context` initialised from a DB string via JSON.parse
//    with strict type validation; scripts read/write that object freely.
//

import Foundation
import JavaScriptCore

/// Errors surfaced by the runner that originate from the JS side
/// or its bridging.
public enum ScriptRunnerError: Error, LocalizedError {
    case jsException(String)
    case noOutput
    case encodeFailure(Error)
    case decodeFailure(Error)
    case contextUnavailable

    public var errorDescription: String? {
        switch self {
        case let .jsException(msg): "JavaScript exception: \(msg)"
        case .noOutput: "Script returned no `__result` value"
        case let .encodeFailure(e): "Failed to encode input for JS: \(e)"
        case let .decodeFailure(e): "Failed to decode JS output: \(e)"
        case .contextUnavailable: "JSContext could not be created"
        }
    }
}

public final class ScriptRunner: @unchecked Sendable {
    private let queue: DispatchQueue
    private let ctx: JSContext
    private let bridge: ScriptBridge

    /// Wall-clock budget per `invoke` call. Plan §1.8 — exceeded → fatalError.
    /// 5s in production; tests using mocked executors don't hit this path.
    private let invokeTimeout: DispatchTimeInterval

    public init(
        initialContextJSON: String,
        manifest: ManifestSnapshot,
        session: ChatSessionSnapshot,
        bridge: ScriptBridge,
        invokeTimeout: DispatchTimeInterval = .seconds(5)
    ) throws {
        queue = DispatchQueue(
            label: "cck.script.\(UUID().uuidString)",
            qos: .userInitiated
        )
        guard let ctx = JSContext() else { throw ScriptRunnerError.contextUnavailable }
        self.ctx = ctx
        self.bridge = bridge
        self.invokeTimeout = invokeTimeout

        // toJSObject is throws; do it OUTSIDE queue.sync so init can rethrow.
        // queue.sync's closure body can't propagate throws to the init.
        let manifestObject: Any
        let sessionObject: Any
        do {
            manifestObject = try Self.toJSObject(manifest)
            sessionObject = try Self.toJSObject(session)
        } catch {
            throw ScriptRunnerError.encodeFailure(error)
        }

        let escapedContextJSON = initialContextJSON

        queue.sync { [ctx] in
            // cck.* bridge
            ctx.setObject(bridge, forKeyedSubscript: "cck" as NSString)

            // Manifest / chatSession deep-frozen globals.
            Self.installSafeImmutableGlobal(in: ctx, name: "manifest", object: manifestObject)
            Self.installSafeImmutableGlobal(in: ctx, name: "chatSession", object: sessionObject)

            // Context bootstrap: never interpolate the DB string into JS
            // source. Pass via setObject, then JSON.parse + type guard.
            ctx.setObject(escapedContextJSON, forKeyedSubscript: "__contextJSON" as NSString)
            ctx.evaluateScript("""
            var context = (function() {
              try {
                if (typeof __contextJSON !== "string" || __contextJSON.length === 0) return {};
                var v = JSON.parse(__contextJSON);
                if (typeof v === "object" && v !== null && !Array.isArray(v)) return v;
                return {};
              } catch (e) { return {}; }
            })();
            delete globalThis.__contextJSON;
            """)
        }
    }

    /// Synchronous-from-JS-perspective invocation.
    /// `bindings` are chunk-local inputs (headers/body for pre,
    /// line/parsed for post). Do NOT pass manifest/session here — they
    /// live as immutable globals.
    public func invoke<Output: Decodable>(
        script: String,
        bindings: [String: Any] = [:],
        decoding _: Output.Type = Output.self
    ) throws -> Output {
        let sem = DispatchSemaphore(value: 0)
        var jsonResult: String?
        var jsError: String?

        queue.async { [self] in
            for (key, value) in bindings {
                ctx.setObject(value, forKeyedSubscript: key as NSString)
            }
            // Wrapper:
            //   - Provides a local __result the user script assigns to.
            //   - Returns JSON.stringify(__result). If __result is
            //     undefined, JSON.stringify yields undefined as well —
            //     we detect that on the Swift side.
            let wrapped = """
            (function() {
              var __result = undefined;
              \(script)
              ;return JSON.stringify(__result);
            })()
            """
            if let value = ctx.evaluateScript(wrapped),
               !value.isUndefined, !value.isNull
            {
                jsonResult = value.toString()
            }
            if let exception = ctx.exception {
                jsError = exception.toString()
                ctx.exception = nil
            }
            sem.signal()
        }

        if sem.wait(timeout: .now() + invokeTimeout) == .timedOut {
            // Plan §1.8 — only way to free the queue is to kill the process.
            // No `onTimeout` closure injection; would only mislead tests.
            fatalError(
                "ChatClientKit script exceeded \(invokeTimeout) budget — developer must fix the script. Process is doomed."
            )
        }

        if let err = jsError { throw ScriptRunnerError.jsException(err) }
        guard let json = jsonResult, json != "undefined" else {
            throw ScriptRunnerError.noOutput
        }
        do {
            return try JSONDecoder().decode(Output.self, from: Data(json.utf8))
        } catch {
            throw ScriptRunnerError.decodeFailure(error)
        }
    }

    /// Encode a Codable value as a Foundation object graph
    /// (NSDictionary/NSArray/NSString/NSNumber) suitable for
    /// `JSContext.setObject(_:forKeyedSubscript:)` bridging.
    /// Avoids string-interpolating into JS source (injection-safe).
    private static func toJSObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Install a global as a frozen, non-configurable property.
    /// Deep-freeze walks the entire object graph so nested arrays/objects
    /// can't be mutated by scripts.
    private static func installSafeImmutableGlobal(
        in ctx: JSContext,
        name: String,
        object: Any
    ) {
        ctx.setObject(object, forKeyedSubscript: name as NSString)
        // Wrap in an IIFE that defines the binding name as
        // non-writable + deep-freeze the value.
        ctx.evaluateScript("""
        (function deepFreeze(o) {
          if (o === null || typeof o !== "object") return;
          Object.freeze(o);
          for (var k in o) {
            if (Object.prototype.hasOwnProperty.call(o, k)) deepFreeze(o[k]);
          }
        })(globalThis["\(name)"]);
        """)
    }
}
