//
//  MessageFlags.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

extension ChatRequestBody.Message {
    var isUser: Bool {
        if case .user = self { return true }
        return false
    }

    var isUserText: Bool {
        guard case let .user(content, _) = self else { return false }
        if case .text = content { return true }
        return false
    }
}

extension [ChatRequestBody.Message] {
    var lastIsUserText: Bool {
        guard let last else { return false }
        return last.isUserText
    }
}

