//
//  ChatRequestConvertible.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

/// A type that can be converted into a canonical `ChatRequestBody`.
public protocol ChatRequestConvertible {
    /// Converts the receiver into a fully materialized `ChatRequestBody`.
    ///
    /// Implementations should normalize their data so identical semantic
    /// requests produce identical payloads, increasing cache efficiency.
    /// - Returns: A normalized `ChatRequestBody`.
    func asChatRequestBody() throws -> ChatRequestBody
}

public extension ChatRequestConvertible {
    /// Convenience helper to encode the canonical request body.
    func encodedBody(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(asChatRequestBody())
    }
}

extension ChatRequestBody: ChatRequestConvertible {
    public func asChatRequestBody() -> ChatRequestBody {
        self
    }
}
