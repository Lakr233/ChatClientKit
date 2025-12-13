//
//  SanitizationRule.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/12/6.
//

import Foundation

enum SanitizationRule: CaseIterable {
    case mergeSystemMessages
    case ensureToolResponses
    case ensureTrailingUserText

    static func applyAll(on messages: [ChatRequestBody.Message]) -> [ChatRequestBody.Message] {
        var mutableMessages = messages
        for rule in allCases {
            rule.apply(on: &mutableMessages)
        }
        return mutableMessages
    }

    func apply(on messages: inout [ChatRequestBody.Message]) {
        switch self {
        case .mergeSystemMessages:
            messages = MessageSanitizer.mergeSystemMessages(messages)
        case .ensureToolResponses:
            MessageSanitizer.ensureToolResponses(messages: &messages)
        case .ensureTrailingUserText:
            MessageSanitizer.ensureTrailingUserText(messages: &messages)
        }
    }
}
