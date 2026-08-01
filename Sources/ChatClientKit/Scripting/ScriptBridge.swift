//
//  ScriptBridge.swift
//  ChatClientKit
//
//  Bridge object exposed to JavaScript as the global `cck`.
//  Includes saveContext (synchronous persistence with 5s watchdog),
//  log, and a small set of crypto / encoding utilities.
//
//  Watchdog semantics(plan §1.8/§8.4):若 onWriteContext > 5s
//  无返回(典型场景:外层调用方持有 WCDB transaction → 锁反转),
//  直接 fatalError 让进程死,不允许挂屏。
//

import CommonCrypto
import Foundation
import JavaScriptCore

@objc public protocol ScriptBridgeExports: JSExport {
    func saveContext(_ value: JSValue)
    func log(_ message: String)
    func base64Encode(_ s: String) -> String
    func base64Decode(_ s: String) -> String
    func sha256(_ s: String) -> String
    func hmacSHA256(_ key: String, message: String) -> String
}

public final class ScriptBridge: NSObject, ScriptBridgeExports, @unchecked Sendable {
    /// Synchronous-semantics write back to durable storage.
    /// Throws are caught and surfaced to the JS side as exceptions.
    /// **Caller responsibility**: closure must be self-contained,
    /// not nested inside any DB transaction held by the streamingChat
    /// caller chain (see plan §8.4 — risk of lock inversion).
    let onWriteContext: @Sendable (String) throws -> Void

    /// How long Swift will wait synchronously for the write closure to
    /// complete before forcing the process down. Plan §1.8 / §8.4.
    /// Hardcoded at 5s in production; configurable for tests.
    let writeTimeout: DispatchTimeInterval

    public init(
        onWriteContext: @escaping @Sendable (String) throws -> Void,
        writeTimeout: DispatchTimeInterval = .seconds(5)
    ) {
        self.onWriteContext = onWriteContext
        self.writeTimeout = writeTimeout
        super.init()
    }

    // MARK: - JSExport

    @objc public func saveContext(_ value: JSValue) {
        // 1. Stringify on the JS side. If it throws (e.g. circular refs),
        //    surface the error to the script.
        guard let ctx = value.context,
              let stringifier = ctx.evaluateScript("JSON.stringify"),
              let json = stringifier.call(withArguments: [value])?.toString(),
              json != "undefined"
        else {
            let ctx = JSContext.current() ?? value.context
            ctx?.exception = JSValue(
                newErrorFromMessage: "saveContext: value is not JSON-serializable",
                in: ctx
            )
            return
        }

        // 2. Cross-queue synchronous wait with 5s budget.
        //    onWriteContext must run on a DIFFERENT queue than the JS
        //    script (we're currently on the ScriptRunner's serial queue);
        //    otherwise we'd deadlock against ourselves.
        let sem = DispatchSemaphore(value: 0)
        // Round 1 codex BLOCKER #4 fix:Swift 6 rejects capturing `var caught`
        // across `DispatchQueue.async`. Use a lock-protected box; semaphore
        // enforces happens-before but the type system needs explicit guard.
        let box = WriteResultBox()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do { try onWriteContext(json) }
            catch { box.set(error: error) }
            sem.signal()
        }
        if sem.wait(timeout: .now() + writeTimeout) == .timedOut {
            fatalError(
                "[CCK] saveContext write blocked > \(writeTimeout) — likely WCDB lock inversion in caller chain"
            )
        }
        if let err = box.get() {
            let ctx = JSContext.current() ?? value.context
            ctx?.exception = JSValue(
                newErrorFromMessage: "saveContext failed: \(err)",
                in: ctx
            )
        }
    }

    @objc public func log(_ message: String) {
        logger.info("[script] \(message)")
    }

    @objc public func base64Encode(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }

    @objc public func base64Decode(_ s: String) -> String {
        guard let data = Data(base64Encoded: s) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc public func sha256(_ s: String) -> String {
        let data = Data(s.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @objc public func hmacSHA256(_ key: String, message: String) -> String {
        let keyData = Data(key.utf8)
        let msgData = Data(message.utf8)
        var mac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { kBuf in
            msgData.withUnsafeBytes { mBuf in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256),
                    kBuf.baseAddress, keyData.count,
                    mBuf.baseAddress, msgData.count,
                    &mac
                )
            }
        }
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

/// Lock-protected one-shot result holder used by `ScriptBridge.saveContext`
/// to ferry the write-back error from the global queue back to the JS thread.
private final class WriteResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}
