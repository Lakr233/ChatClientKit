//
//  ChatMessageBuilder.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import Foundation

@resultBuilder
public enum ChatMessageBuilder {
    public static func buildBlock(
        _ components: [ChatRequest.Message]...
    ) -> [ChatRequest.Message] {
        components.reduce(into: []) { result, element in
            result.append(contentsOf: element)
        }
    }

    public static func buildExpression(
        _ expression: ChatRequest.Message
    ) -> [ChatRequest.Message] {
        [expression]
    }

    public static func buildExpression(
        _ expression: [ChatRequest.Message]
    ) -> [ChatRequest.Message] {
        expression
    }

    public static func buildOptional(
        _ component: [ChatRequest.Message]?
    ) -> [ChatRequest.Message] {
        component ?? []
    }

    public static func buildEither(
        first component: [ChatRequest.Message]
    ) -> [ChatRequest.Message] {
        component
    }

    public static func buildEither(
        second component: [ChatRequest.Message]
    ) -> [ChatRequest.Message] {
        component
    }

    public static func buildArray(
        _ components: [[ChatRequest.Message]]
    ) -> [ChatRequest.Message] {
        components.flatMap(\.self)
    }

    public static func buildLimitedAvailability(
        _ component: [ChatRequest.Message]
    ) -> [ChatRequest.Message] {
        component
    }
}
