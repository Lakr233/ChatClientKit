//
//  EmptyRequestSanitizer.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

struct EmptyRequestSanitizer: RequestSanitizing {
    func sanitize(_ body: ChatRequestBody) -> ChatRequestBody {
        body
    }
}

