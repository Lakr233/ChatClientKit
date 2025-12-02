//
//  ReasoningDetail.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/11.
//

import Foundation

/// A structured reasoning block emitted by reasoning-capable models.
///
/// Reasoning blocks can be streamed over multiple deltas. Use the provided
/// helper to merge text fragments when reconstructing prior context.
public struct ReasoningDetail: Codable, Sendable, Equatable, Hashable {
    public let id: String?
    public let type: String
    public var text: String?
    public let data: String?
    public let format: String?
    public let index: Int?

    public init(
        id: String? = nil,
        type: String,
        text: String? = nil,
        data: String? = nil,
        format: String? = nil,
        index: Int? = nil,
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.data = data
        self.format = format
        self.index = index
    }

    /// Merges another reasoning detail into the receiver when they describe the
    /// same reasoning stream.
    ///
    /// Currently text fragments are appended in order; other fields prefer the
    /// latest non-nil value.
    public mutating func merge(with other: ReasoningDetail) {
        guard matchesContinuation(of: other) else { return }
        if let incomingText = other.text, !incomingText.isEmpty {
            if let existingText = text, !existingText.isEmpty {
                text = existingText + incomingText
            } else {
                text = incomingText
            }
        }
    }

    /// Returns true if the two details should be merged as a single stream.
    public func matchesContinuation(of other: ReasoningDetail) -> Bool {
        if let id, let otherID = other.id {
            return id == otherID
        }
        if let index, let otherIndex = other.index {
            return index == otherIndex && type == other.type && format == other.format
        }
        return type == other.type && format == other.format
    }
}
