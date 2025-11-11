//
//  ToolCallRequest.swift
//  ChatClientKit
//
//  Created by 秋星桥 on 2/27/25.
//

import Foundation

public struct ToolCallRequest: Codable, Equatable, Hashable, Sendable {
    public var id: UUID = .init()

    public let name: String
    public let args: String

    init(name: String, args: String) {
        self.name = name
        self.args = args
    }
}
