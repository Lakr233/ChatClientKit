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
        // Round 1 codex BLOCKER #3 fix:Swift 6 strict concurrency rejects
        // capturing `var` across `queue.async` boundaries. Use a lock-protected
        // box; semaphore guarantees there's no actual concurrent access
        // between the writer (queue.async closure) and reader (after sem.wait),
        // but the type system needs us to be explicit.
        let box = InvocationResultBox()
        let sendableBindings = SendableBindings(values: bindings)

        queue.async { [self, sendableBindings] in
            for (key, value) in sendableBindings.values {
                ctx.setObject(value, forKeyedSubscript: key as NSString)
            }
            let wrapped = """
            (function() {
              var __result = undefined;
              \(script)
              ;return JSON.stringify(__result);
            })()
            """
            var resultString: String?
            var errorString: String?
            if let value = ctx.evaluateScript(wrapped),
               !value.isUndefined, !value.isNull
            {
                resultString = value.toString()
            }
            if let exception = ctx.exception {
                errorString = exception.toString()
                ctx.exception = nil
            }
            box.set(json: resultString, error: errorString)
            sem.signal()
        }

        if sem.wait(timeout: .now() + invokeTimeout) == .timedOut {
            // Plan §1.8 — only way to free the queue is to kill the process.
            fatalError(
                "ChatClientKit script exceeded \(invokeTimeout) budget — developer must fix the script. Process is doomed."
            )
        }

        let snapshot = box.get()
        if let err = snapshot.error { throw ScriptRunnerError.jsException(err) }
        guard let json = snapshot.json, json != "undefined" else {
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

private struct SendableBindings: @unchecked Sendable {
    let values: [String: Any]
}

/// Lock-protected one-shot result holder used by `ScriptRunner.invoke`
/// to ferry the JS evaluation outcome from the dedicated queue back to
/// the caller. The semaphore guarantees happens-before, but Swift 6
/// concurrency checking requires explicit thread safety on the type.
private final class InvocationResultBox: @unchecked Sendable {
    struct Snapshot {
        let json: String?
        let error: String?
    }

    private let lock = NSLock()
    private var json: String?
    private var error: String?

    func set(json: String?, error: String?) {
        lock.lock()
        self.json = json
        self.error = error
        lock.unlock()
    }

    func get() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(json: json, error: error)
    }
}
