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

    init(id: String? = nil, name: String, args: String) {
        var identifier = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if identifier.isEmpty { identifier = UUID().uuidString }
        self.id = identifier
        self.name = name
        self.args = args
    }
}
