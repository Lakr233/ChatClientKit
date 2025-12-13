//
//  EmptyRequestSanitizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

public struct EmptyRequestSanitizer: RequestSanitizing {
    public init() {}

    public func sanitize(_ body: ChatRequestBody) -> ChatRequestBody {
        body
    }
}
