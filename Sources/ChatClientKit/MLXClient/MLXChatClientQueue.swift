//
//  MLXChatClientQueue.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

public final class MLXChatClientQueue: @unchecked Sendable {
    public nonisolated static let shared = MLXChatClientQueue()

    private let semaphore = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var runningTokens: Set<UUID> = []

    private init() {}

    @discardableResult
    public func acquire() -> UUID {
        let token = UUID()
        logger.debug("MLXChatClientQueue.acquire token: \(token.uuidString)")
        semaphore.wait()

        lock.lock()
        runningTokens.insert(token)
        lock.unlock()

        return token
    }

    public func release(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard runningTokens.remove(token) != nil else {
            return
        }

        logger.debug("MLXChatClientQueue.release token: \(token.uuidString)")
        semaphore.signal()
    }
}
