//
//  ImageContent.swift
//  ChatClientKit
//
//  Created by qaq on 6/12/2025.
//

import Foundation

public struct ImageContent: Sendable, Equatable {
    public let data: Data
    public let mimeType: String?

    public init(data: Data, mimeType: String? = nil) {
        self.data = data
        self.mimeType = mimeType
    }
}
