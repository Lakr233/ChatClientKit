//
//  ChatResponse.swift
//  ChatClientKit
//
//  Created by qaq on 7/12/2025.
//

import Foundation

public struct ChatResponse: Sendable, Equatable {
    public var reasoning: String
    public var text: String
    public var images: [ImageContent]
    public var tools: [ToolRequest]

    public init(reasoning: String, text: String, images: [ImageContent], tools: [ToolRequest]) {
        self.reasoning = reasoning
        self.text = text
        self.images = images
        self.tools = tools
    }

    public init(chunks: [ChatResponseChunk]) {
        var reasoning = ""
        var text = ""
        var images: [ImageContent] = []
        var tools: [ToolRequest] = []
        for chunk in chunks {
            switch chunk {
            case let .reasoning(string): reasoning += string
            case let .text(string): text += string
            case let .image(imageContent): images.append(imageContent)
            case let .tool(toolRequest): tools.append(toolRequest)
            }
        }
        self.reasoning = reasoning
        self.text = text
        self.images = images
        self.tools = tools
    }
}
