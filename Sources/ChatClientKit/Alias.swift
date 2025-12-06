//
//  Alias.swift
//  ChatClientKit
//
//  Created by qaq on 6/12/2025.
//

import Foundation

// Centralized type aliases for ChatClientKit to keep naming aligned and avoid
// scattering small aliases across multiple files.

// Bridging aliases for remote chat clients.
typealias RemoteChatClientDependencies = RemoteClientDependencies
typealias RemoteChatErrorExtractor = RemoteCompletionsChatErrorExtractor
typealias RemoteResponsesErrorExtractor = RemoteResponsesChatErrorExtractor
typealias RemoteResponsesChatErrorExtractor = RemoteCompletionsChatErrorExtractor

public typealias ToolDefinition = ChatRequestBody.Tool

public extension ChatRequest {
    typealias BuildComponent = @Sendable (inout ChatRequest) -> Void
    typealias Message = ChatRequestBody.Message
    typealias MessageContent = ChatRequestBody.Message.MessageContent
    typealias ContentPart = ChatRequestBody.Message.ContentPart
    typealias Tool = ChatRequestBody.Tool
}
