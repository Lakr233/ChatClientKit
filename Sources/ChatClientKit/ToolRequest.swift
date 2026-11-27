//
//  ToolRequest.swift
//  ChatClientKit
//
//  Created by 秋星桥 on 2/27/25.
//

import Foundation

public struct ToolRequest: Codable, Equatable, Hashable, Sendable {
    public var id: String = UUID().uuidString

    public let name: String
    public let args: String

    /// Provider-specific fields the model attached to this tool call beyond
    /// `id`, `type` and `function`, such as Gemini's
    /// `extra_content.google.thought_signature`. They must be sent back
    /// unchanged on the follow-up request of the same tool loop.
    ///
    /// Kept in memory only: excluded from `Codable` so callers that persist
    /// a `ToolRequest` keep their stored format unchanged.
    public var extraFields: [String: AnyCodingValue]? = nil

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case args
    }

    public init(
        id: String? = nil,
        name: String,
        args: String,
        extraFields: [String: AnyCodingValue]? = nil
    ) {
        var identifier = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if identifier.isEmpty { identifier = UUID().uuidString }
        self.id = identifier
        self.name = name
        self.args = args
        self.extraFields = (extraFields?.isEmpty ?? true) ? nil : extraFields
    }
}
